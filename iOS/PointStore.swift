import Foundation

/// Stores points on device only, one JSON-Lines file per local day:
/// `Application Support/Tracks/2026-11-12.jsonl`.
///
/// Privacy:
/// * Files use iOS Data Protection (encrypted with a key tied to your passcode). We use
///   `completeUntilFirstUserAuthentication` so the app can keep writing in the background while
///   the phone is locked; before the first unlock after a reboot the files are unreadable.
/// * The folder is excluded from iCloud/iTunes backups.
/// * Nothing is ever sent over the network.
final class PointStore {
    static let shared = PointStore()

    let directory: URL
    private let queue = DispatchQueue(label: "posxy.pointstore")
    private let protection = FileProtectionType.completeUntilFirstUserAuthentication
    private let encoder = TrackJSON.encoder()   // only used on `queue`
    private let decoder = TrackJSON.decoder()   // only used on `queue`

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }
    static func date(fromDayKey key: String) -> Date? { dayFormatter.date(from: key) }

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Tracks", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        directory = dir
    }

    private func fileURL(dayKey: String) -> URL {
        directory.appendingPathComponent("\(dayKey).jsonl")
    }

    // MARK: Writing

    func append(_ point: TrackPoint) {
        queue.async { [self] in
            guard var line = try? encoder.encode(point) else { return }
            line.append(0x0A)
            let url = fileURL(dayKey: Self.dayKey(point.t))
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: line, attributes: [.protectionKey: protection])
                return
            }
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                print("PointStore write failed: \(error)")
            }
        }
    }

    func delete(dayKey: String) {
        queue.sync {
            try? FileManager.default.removeItem(at: fileURL(dayKey: dayKey))
        }
    }

    func deleteAll() {
        queue.sync {
            let fm = FileManager.default
            for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: Reading

    /// Sorted list of days that have data, e.g. ["2026-11-10", "2026-11-11"].
    func dayKeys() -> [String] {
        queue.sync { dayKeysUnlocked() }
    }

    private func dayKeysUnlocked() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.filter { $0.hasSuffix(".jsonl") }
            .map { String($0.dropLast(".jsonl".count)) }
            .sorted()
    }

    func points(dayKey: String) -> [TrackPoint] {
        queue.sync { readUnlocked(dayKey: dayKey) }
    }

    func points(from start: Date, to end: Date) -> [TrackPoint] {
        queue.sync {
            let lo = Self.dayKey(start), hi = Self.dayKey(end)
            return dayKeysUnlocked()
                .filter { $0 >= lo && $0 <= hi }
                .flatMap { readUnlocked(dayKey: $0) }
                .filter { $0.t >= start && $0.t <= end }
        }
    }

    func count(dayKey: String) -> Int {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL(dayKey: dayKey)) else { return 0 }
            return data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
    }

    func lastPoint() -> TrackPoint? {
        queue.sync {
            guard let key = dayKeysUnlocked().last else { return nil }
            return readUnlocked(dayKey: key).last
        }
    }

    func totalBytes() -> Int {
        queue.sync {
            let fm = FileManager.default
            return dayKeysUnlocked().reduce(0) { sum, key in
                let attrs = try? fm.attributesOfItem(atPath: fileURL(dayKey: key).path)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                return sum + size
            }
        }
    }

    private func readUnlocked(dayKey: String) -> [TrackPoint] {
        guard let data = try? Data(contentsOf: fileURL(dayKey: dayKey)) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(TrackPoint.self, from: Data($0)) }
    }
}
