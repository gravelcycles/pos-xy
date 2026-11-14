import Foundation
import SwiftUI

struct DayInfo: Identifiable, Hashable {
    var id: Date { day }
    let day: Date
    let pointCount: Int
}

struct DayData {
    let points: [TrackPoint]
    let segments: [Segment]
    /// Silence longer than this is a gap (depends on the recording frequency).
    let gap: TimeInterval
}

struct LockedFile: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
}

/// Everything the viewer has loaded. Kept in memory only: the viewer writes nothing to disk
/// except the map-tile cache, so quitting forgets your history.
final class TrackLibrary: ObservableObject {
    static let shared = TrackLibrary()

    @Published private(set) var points: [TrackPoint] = []
    @Published private(set) var days: [DayInfo] = []
    @Published private(set) var fileNames: [String] = []
    @Published private(set) var locked: [LockedFile] = []
    @Published var showImporter = false
    @Published var errorMessage: String?
    /// Bumped whenever the loaded data changes.
    @Published private(set) var version = 0
    /// Home, Work and other places, detected in the background after each import.
    @Published private(set) var places: [Place] = []

    private var cache: [Date: DayData] = [:]
    private var lastPassphrase: String?

    func open(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                ingest(try Data(contentsOf: url), name: url.lastPathComponent)
            } catch {
                errorMessage = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func ingest(_ data: Data, name: String) {
        if ExportCodec.isEncrypted(data) {
            // Try the passphrase that worked last time before asking again.
            if let pw = lastPassphrase, let pts = try? ExportCodec.decode(data, passphrase: pw) {
                merge(pts, name: name)
            } else {
                locked.append(LockedFile(name: name, data: data))
            }
            return
        }
        do {
            merge(try ExportCodec.decode(data, passphrase: nil), name: name)
        } catch {
            errorMessage = "\(name): \(error.localizedDescription)"
        }
    }

    func unlock(_ file: LockedFile, passphrase: String) throws {
        let pts = try ExportCodec.decode(file.data, passphrase: passphrase)
        lastPassphrase = passphrase
        locked.removeAll { $0.id == file.id }
        merge(pts, name: file.name)
        for other in locked {
            if let more = try? ExportCodec.decode(other.data, passphrase: passphrase) {
                locked.removeAll { $0.id == other.id }
                merge(more, name: other.name)
            }
        }
    }

    func skip(_ file: LockedFile) {
        locked.removeAll { $0.id == file.id }
    }

    func clear() {
        points = []
        days = []
        fileNames = []
        locked = []
        cache = [:]
        lastPassphrase = nil
        motion = []
        version += 1
        places = []
    }

    /// Motion-coprocessor history from the loaded files (labels gaps without points).
    private(set) var motion: [MotionSpan] = []

    private func merge(_ contents: ExportContents, name: String) {
        if !contents.motion.isEmpty { motion = MotionSpans.normalized(motion + contents.motion) }
        let new = contents.points
        var seen = Set<Int64>()
        var all: [TrackPoint] = []
        all.reserveCapacity(points.count + new.count)
        for p in (points + new).sorted(by: { $0.t < $1.t }) {
            guard p.t.timeIntervalSince1970.magnitude < 1e11 else { continue }   // garbage timestamp
            let key = Int64((p.t.timeIntervalSince1970 * 1000).rounded())
            if seen.insert(key).inserted { all.append(p) }
        }
        points = all
        fileNames.append(name)
        cache = [:]
        version += 1
        refreshPlaces()

        let cal = Calendar.current
        let grouped = Dictionary(grouping: all) { cal.startOfDay(for: $0.t) }
        days = grouped.map { DayInfo(day: $0.key, pointCount: $0.value.count) }
            .sorted { $0.day > $1.day }
    }

    private func refreshPlaces() {
        let snapshot = points
        let motionSnapshot = motion
        let forVersion = version
        DispatchQueue.global(qos: .utility).async {
            let cal = Calendar.current
            let groups = Dictionary(grouping: snapshot) { cal.startOfDay(for: $0.t) }
            let detected = Places.detect(days: groups.keys.sorted().compactMap { groups[$0] }, motion: motionSnapshot)
            DispatchQueue.main.async {
                if self.version == forVersion { self.places = detected }
            }
        }
    }

    /// Cleaned points and segments for one local calendar day (cached).
    func dayData(for day: Date) -> DayData {
        if let cached = cache[day] { return cached }
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        let lo = lowerBound(day), hi = lowerBound(next)
        let cleaned = Segmenter.clean(Array(points[lo..<hi]))
        let dayMotion = MotionSpans.overlapping(motion, from: day, to: next)
        let data = DayData(points: cleaned, segments: Segmenter.segments(cleaned, motion: dayMotion),
                           gap: Segmenter.gapThreshold(cleaned))
        cache[day] = data
        return data
    }

    private func lowerBound(_ date: Date) -> Int {
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].t < date { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
