import Foundation

/// Manual activity corrections ("that drive was a train"), kept on the iPhone in one small file
/// `Application Support/Corrections.json`, same Data Protection as the tracks, not backed up.
/// They're applied on top of the automatic segments everywhere and included in exports.
final class CorrectionStore {
    static let shared = CorrectionStore()

    private let url: URL
    private let queue = DispatchQueue(label: "posxy.corrections")
    private var cache: [ActivityCorrection]?

    private init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("Corrections.json")
    }

    private func loadUnlocked() -> [ActivityCorrection] {
        if let cache { return cache }
        let list = (try? Data(contentsOf: url)).flatMap { try? TrackJSON.decoder().decode([ActivityCorrection].self, from: $0) } ?? []
        cache = list
        return list
    }

    private func saveUnlocked(_ list: [ActivityCorrection]) {
        cache = list
        guard let data = try? TrackJSON.encoder().encode(list) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        try? u.setResourceValues(values)
    }

    /// All corrections overlapping [start, end), in the order they were made (later wins).
    func corrections(from start: Date, to end: Date) -> [ActivityCorrection] {
        queue.sync { loadUnlocked().filter { $0.end > start && $0.start < end } }
    }

    /// Marks [start, end] as `act`, replacing earlier corrections of the same stretch.
    func set(_ act: ActivityType, from start: Date, to end: Date) {
        queue.sync {
            var list = Corrections.removing(loadUnlocked(), from: start, to: end)
            list.append(ActivityCorrection(start: start, end: end, act: act))
            saveUnlocked(list)
        }
    }

    /// "Back to automatic" for [start, end].
    func reset(from start: Date, to end: Date) {
        queue.sync { saveUnlocked(Corrections.removing(loadUnlocked(), from: start, to: end)) }
    }

    func isCorrected(from start: Date, to end: Date) -> Bool {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return false }
        return corrections(from: start, to: end).contains {
            min($0.end, end).timeIntervalSince(max($0.start, start)) >= 0.5 * span
        }
    }

    func delete(dayKey: String) {
        guard let day = PointStore.date(fromDayKey: dayKey) else { return }
        let next = day.addingTimeInterval(86_400)
        queue.sync { saveUnlocked(loadUnlocked().filter { !($0.start >= day && $0.start < next) }) }
    }

    func deleteAll() {
        queue.sync { saveUnlocked([]) }
    }
}
