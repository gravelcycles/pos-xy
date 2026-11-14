import Foundation

/// The phone's motion-coprocessor history (walk / run / bike / drive / still), backfilled by
/// LocationRecorder whenever the app wakes up. One JSON-Lines file per local day of the span's
/// start in `Application Support/Motion/`, same Data Protection and backup exclusion as the tracks.
final class MotionStore {
    static let shared = MotionStore()

    private let directory: URL
    private let queue = DispatchQueue(label: "posxy.motionstore")
    private let protection = FileProtectionType.completeUntilFirstUserAuthentication
    private let encoder = TrackJSON.encoder()   // only used on `queue`
    private let decoder = TrackJSON.decoder()   // only used on `queue`

    private init() {
        let fm = FileManager.default
        var dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Motion", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        directory = dir
    }

    private func url(dayKey: String) -> URL { directory.appendingPathComponent("\(dayKey).jsonl") }

    func append(_ spans: [MotionSpan]) {
        guard !spans.isEmpty else { return }
        queue.async { [self] in
            let byDay = Dictionary(grouping: spans) { PointStore.dayKey($0.start) }
            let fm = FileManager.default
            for (key, daySpans) in byDay {
                var data = Data()
                for s in daySpans {
                    guard let line = try? encoder.encode(s) else { continue }
                    data.append(line)
                    data.append(0x0A)
                }
                let file = url(dayKey: key)
                if !fm.fileExists(atPath: file.path) {
                    fm.createFile(atPath: file.path, contents: data, attributes: [.protectionKey: protection])
                } else if let h = try? FileHandle(forWritingTo: file) {
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                    try? h.close()
                }
            }
        }
    }

    /// Spans overlapping [start, end), sorted and de-duplicated.
    func spans(from start: Date, to end: Date) -> [MotionSpan] {
        queue.sync {
            let fm = FileManager.default
            let lo = PointStore.dayKey(start.addingTimeInterval(-86_400))   // spans can cross midnight
            let hi = PointStore.dayKey(end)
            let keys = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasSuffix(".jsonl") }
                .map { String($0.dropLast(".jsonl".count)) }
                .filter { $0 >= lo && $0 <= hi }
            var out: [MotionSpan] = []
            for key in keys {
                guard let data = try? Data(contentsOf: url(dayKey: key)) else { continue }
                for line in data.split(separator: 0x0A) {
                    if let s = try? decoder.decode(MotionSpan.self, from: Data(line)), s.end > start, s.start < end {
                        out.append(s)
                    }
                }
            }
            return MotionSpans.normalized(out)
        }
    }

    func spans(dayKey: String) -> [MotionSpan] {
        guard let day = PointStore.date(fromDayKey: dayKey) else { return [] }
        return spans(from: day, to: day.addingTimeInterval(86_400))
    }

    func delete(dayKey: String) {
        queue.sync { try? FileManager.default.removeItem(at: url(dayKey: dayKey)) }
    }

    func deleteAll() {
        queue.sync {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}
