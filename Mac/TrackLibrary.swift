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
            if let pw = lastPassphrase, let pts = try? ExportCodec.decodePoints(data, passphrase: pw) {
                merge(pts, name: name)
            } else {
                locked.append(LockedFile(name: name, data: data))
            }
            return
        }
        do {
            merge(try ExportCodec.decodePoints(data, passphrase: nil), name: name)
        } catch {
            errorMessage = "\(name): \(error.localizedDescription)"
        }
    }

    func unlock(_ file: LockedFile, passphrase: String) throws {
        let pts = try ExportCodec.decodePoints(file.data, passphrase: passphrase)
        lastPassphrase = passphrase
        locked.removeAll { $0.id == file.id }
        merge(pts, name: file.name)
        for other in locked {
            if let more = try? ExportCodec.decodePoints(other.data, passphrase: passphrase) {
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
        version += 1
    }

    private func merge(_ new: [TrackPoint], name: String) {
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

        let cal = Calendar.current
        let grouped = Dictionary(grouping: all) { cal.startOfDay(for: $0.t) }
        days = grouped.map { DayInfo(day: $0.key, pointCount: $0.value.count) }
            .sorted { $0.day > $1.day }
    }

    /// Cleaned points and segments for one local calendar day (cached).
    func dayData(for day: Date) -> DayData {
        if let cached = cache[day] { return cached }
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        let lo = lowerBound(day), hi = lowerBound(next)
        let cleaned = Segmenter.clean(Array(points[lo..<hi]))
        let data = DayData(points: cleaned, segments: Segmenter.segments(cleaned), gap: Segmenter.gapThreshold(cleaned))
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
