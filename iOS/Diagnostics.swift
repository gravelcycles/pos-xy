import Foundation
import UIKit

/// On-device diagnostics log, for working out what happens to recording in the background.
///
/// * Never contains coordinates, so the exported file is safe to share.
/// * One file per day in `Application Support/Diagnostics/YYYY-MM-DD.log`, kept 14 days,
///   excluded from backups, same Data Protection class as the tracks.
/// * Each line: local time, app state (fg / inactive / bg), category, message.
final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()

    struct Entry: Identifiable {
        let id = UUID()
        let line: String
    }

    /// The most recent lines, newest last (main thread only).
    @Published private(set) var recent: [Entry] = []

    private let queue = DispatchQueue(label: "posxy.diagnostics")
    private let directory: URL
    private let protection = FileProtectionType.completeUntilFirstUserAuthentication
    private let defaults = UserDefaults.standard
    private var lastHeartbeatWrite = Date.distantPast

    private enum Keys {
        static let lastAlive = "diag.lastAlive"
        static let cleanExit = "diag.cleanExit"
    }

    private static let lineTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return f
    }()
    private static let fileDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Previous run's last sign of life and whether it ended cleanly (read once at launch).
    private(set) var previousLastAlive: Date?
    private(set) var previousEndedCleanly = true
    private(set) var launchedByLocationEvent = false

    private init() {
        let fm = FileManager.default
        var dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        directory = dir
        previousLastAlive = defaults.object(forKey: Keys.lastAlive) as? Date
        previousEndedCleanly = defaults.object(forKey: Keys.cleanExit) as? Bool ?? true
    }

    // MARK: Logging

    /// Appends one line. Safe from any thread; prefer calling on main (the app state is read there).
    func log(_ category: String, _ message: String) {
        let now = Date()
        let state = Thread.isMainThread ? Self.stateCode(UIApplication.shared.applicationState) : "?"
        let line = "\(Self.lineTime.string(from: now)) [\(state)] \(category.padding(toLength: 9, withPad: " ", startingAt: 0)) \(message)"
        let url = directory.appendingPathComponent("\(Self.fileDay.string(from: now)).log")
        queue.async { [protection] in
            guard let data = (line + "\n").data(using: .utf8) else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: data, attributes: [.protectionKey: protection])
                return
            }
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            }
        }
        let entry = Entry(line: line)
        if Thread.isMainThread {
            append(entry)
        } else {
            DispatchQueue.main.async { self.append(entry) }
        }
    }

    private func append(_ e: Entry) {
        recent.append(e)
        if recent.count > 400 { recent.removeFirst(recent.count - 400) }
    }

    static func stateCode(_ s: UIApplication.State) -> String {
        switch s {
        case .active: return "fg"
        case .inactive: return "in"
        case .background: return "bg"
        @unknown default: return "??"
        }
    }

    // MARK: Liveness (detects runs that ended without warning)

    /// Call often (location deliveries, timer ticks). Writes at most every 30 s.
    func heartbeat() {
        let now = Date()
        guard now.timeIntervalSince(lastHeartbeatWrite) > 30 else { return }
        lastHeartbeatWrite = now
        defaults.set(now, forKey: Keys.lastAlive)
    }

    /// Call from application(_:didFinishLaunchingWithOptions:).
    func appLaunched(options: [UIApplication.LaunchOptionsKey: Any]?) {
        launchedByLocationEvent = options?[.location] != nil
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"
        log("launch", "Pos XY \(version) on iOS \(UIDevice.current.systemVersion), \(UIDevice.current.model). "
            + (launchedByLocationEvent ? "Launched BY iOS in the background for a location event."
                                       : "Launched normally (by you, or iOS pre-warming)."))
        if let last = previousLastAlive {
            let ago = Self.duration(Date().timeIntervalSince(last))
            if previousEndedCleanly {
                log("launch", "Previous run ended cleanly; last sign of life \(ago) ago.")
            } else {
                log("launch", "Previous run STOPPED WITHOUT WARNING; last sign of life \(ago) ago "
                    + "(iOS killed it to free memory, it crashed, or it was force-quit while suspended).")
            }
        }
        defaults.set(false, forKey: Keys.cleanExit)
        defaults.set(Date(), forKey: Keys.lastAlive)
        logPowerState(reason: "at launch")
        observeSystem()
        pruneOldFiles()
    }

    private func observeSystem() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log("app", "Will terminate (force-quit while running, or iOS shutting it down).")
            self?.defaults.set(true, forKey: Keys.cleanExit)
            self?.defaults.set(Date(), forKey: Keys.lastAlive)
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log("app", "Memory warning: iOS may kill the app soon.")
        }
        nc.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log("device", "Locked.")
        }
        nc.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { [weak self] _ in
            self?.log("device", "Unlocked.")
        }
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.logPowerState(reason: "changed")
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.logPowerState(reason: "thermal changed")
        }
    }

    func logPowerState(reason: String) {
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled ? "ON" : "off"
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "?"
        }
        log("power", "Low Power Mode \(lpm), thermal \(thermal) (\(reason)).")
    }

    // MARK: Files

    private func pruneOldFiles() {
        queue.async { [directory] in
            let fm = FileManager.default
            let cutoff = Self.fileDay.string(from: Date().addingTimeInterval(-14 * 86_400))
            for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".log") {
                if String(name.dropLast(4)) < cutoff { try? fm.removeItem(at: directory.appendingPathComponent(name)) }
            }
        }
    }

    /// Writes the last `days` days into one temporary file for sharing.
    func makeExport(days: Int = 7) -> URL? {
        queue.sync {
            let fm = FileManager.default
            let names = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasSuffix(".log") }.sorted().suffix(days)
            var text = "Pos XY diagnostics (no coordinates). Exported \(Self.lineTime.string(from: Date()))\n\n"
            for name in names {
                if let s = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) { text += s }
            }
            let url = fm.temporaryDirectory.appendingPathComponent("PosXY diagnostics \(Self.fileDay.string(from: Date())).txt")
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                return url
            } catch {
                return nil
            }
        }
    }

    func clear() {
        queue.sync {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        recent.removeAll()
        log("diag", "Log cleared.")
    }

    static func duration(_ s: TimeInterval) -> String {
        if s < 90 { return "\(Int(s)) s" }
        if s < 5400 { return "\(Int(s / 60)) min" }
        if s < 172_800 { return String(format: "%.1f h", s / 3600) }
        return "\(Int(s / 86_400)) days"
    }
}
