import Foundation

/// Explains, in plain words, why no new point has been saved for a while.
/// Pure logic (Foundation only) so it can be tested off-device; the main screen shows the result.
enum RecordingHealth {
    struct Snapshot {
        var now = Date()
        var isRecording = false
        var isPaused = false
        var permissionProblem = false        // denied / While Using / precise off: warned about elsewhere
        var interval = 0                     // seconds between timed points; 0 = continuous
        var nextPointAt: Date?
        var isTakingPoint = false
        var lastPointAt: Date?
        var lastDeliveryAt: Date?            // any location update from iOS, saved or not
        var lastDroppedAccuracy: Double?     // last fix thrown away for being too rough…
        var lastDroppedAt: Date?             // …and when
        var stillSince: Date?                // motion chip says stationary since
        var isGPSResting = false             // Smart mode dropped to coarse accuracy
        var appStartedAt: Date?
        var launchedByIOS = false
        var previousRunEndedUnexpectedly = false
        var previousLastAlive: Date?
    }

    struct Explanation: Equatable {
        enum Tone { case info, warning }
        var symbol: String
        var text: String
        var tone: Tone
    }

    static func explain(_ s: Snapshot) -> Explanation? {
        guard s.isRecording, !s.isPaused, !s.permissionProblem else { return nil }
        if s.isTakingPoint {
            return Explanation(symbol: "location.magnifyingglass", text: "Getting a GPS fix…", tone: .info)
        }
        let age = s.lastPointAt.map { s.now.timeIntervalSince($0) } ?? .infinity
        let expected: TimeInterval = s.interval > 0 ? TimeInterval(s.interval) + 120 : 300
        guard age >= expected else { return nil }
        let ago = age.isFinite ? duration(age) : nil

        if let at = s.lastDroppedAt, let acc = s.lastDroppedAccuracy, s.now.timeIntervalSince(at) < 10 * 60 {
            return Explanation(symbol: "antenna.radiowaves.left.and.right.slash",
                               text: "Weak GPS signal: the last fix was ±\(Int(acc)) m, too rough to save. Indoors, underground, or in a plane away from the window?",
                               tone: .warning)
        }
        if s.interval > 0, let next = s.nextPointAt, next > s.now {
            return Explanation(symbol: "clock",
                               text: "Timed mode: the next point is due at \(time(next)).", tone: .info)
        }
        if let still = s.stillSince {
            var text = "You've been still since \(time(still)). Pos XY saves a point once you've moved about 15 m, so there's nothing new to record."
            if s.isGPSResting { text += " The GPS is resting until you move." }
            return Explanation(symbol: "figure.stand", text: text, tone: .info)
        }
        if s.launchedByIOS, s.previousRunEndedUnexpectedly, let started = s.appStartedAt, let alive = s.previousLastAlive,
           s.now.timeIntervalSince(started) < 30 * 60 {
            return Explanation(symbol: "arrow.clockwise",
                               text: "iOS stopped Pos XY around \(time(alive)) and restarted it at \(time(started)) when you moved. Motion history fills in what you were doing in between.",
                               tone: .info)
        }
        if s.lastDeliveryAt.map({ s.now.timeIntervalSince($0) > 10 * 60 }) ?? true {
            let since = s.lastDeliveryAt.map { " for \(duration(s.now.timeIntervalSince($0)))" } ?? ""
            return Explanation(symbol: "location.slash",
                               text: "No location updates from iOS\(since). Either you haven't moved (Pos XY records about every 15 m) or there's no GPS signal.",
                               tone: .info)
        }
        return Explanation(symbol: "questionmark.circle",
                           text: "No new points\(ago.map { " for \($0)" } ?? ""), although iOS is sending locations. Diagnostics has the details.",
                           tone: .warning)
    }

    static func duration(_ s: TimeInterval) -> String {
        if s < 90 { return "\(Int(s)) s" }
        if s < 5400 { return "\(Int((s / 60).rounded())) min" }
        if s < 172_800 { return String(format: "%.1f h", s / 3600) }
        return "\(Int(s / 86_400)) days"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    static func time(_ d: Date) -> String { timeFormatter.string(from: d) }
}
