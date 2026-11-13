import Foundation

/// The small slice of recorder state that the Lock Screen widgets and the Control Center
/// controls display. The app writes it to the App Group's UserDefaults; the widget extension
/// only reads it.
///
/// Privacy: deliberately no coordinates, place names or activity. The Lock Screen is visible to
/// anyone holding the phone, so it only says whether recording is on and how many points today.
struct RecordingStatus: Codable, Equatable {
    var isRecording = false
    var pausedUntil: Date?
    /// Local day (`yyyy-MM-dd`) that `pointsToday` belongs to.
    var dayKey = ""
    var pointsToday = 0
    var lastFix: Date?
    /// Seconds between timed points; 0 = continuous.
    var intervalSeconds = 0

    func isPaused(at date: Date = Date()) -> Bool {
        isRecording && (pausedUntil.map { $0 > date } ?? false)
    }

    /// Points recorded on the local day containing `date` (0 once that day has rolled over).
    func points(on date: Date = Date()) -> Int {
        dayKey == Self.dayKey(date) ? pointsToday : 0
    }

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Sample shown in the widget gallery.
    static var preview: RecordingStatus {
        RecordingStatus(isRecording: true, pausedUntil: nil, dayKey: dayKey(Date()), pointsToday: 248,
                        lastFix: Date().addingTimeInterval(-90), intervalSeconds: 0)
    }
}

/// App Group storage shared by the app and the widget extension.
enum SharedStatusStore {
    /// `group.$(APP_BUNDLE_ID)`, expanded into both Info.plists at build time.
    static let groupID = Bundle.main.object(forInfoDictionaryKey: "PosXYAppGroup") as? String

    private static let key = "recordingStatus.v1"
    private static var defaults: UserDefaults? { groupID.flatMap { UserDefaults(suiteName: $0) } }

    static func read() -> RecordingStatus {
        guard let data = defaults?.data(forKey: key),
              let status = try? JSONDecoder().decode(RecordingStatus.self, from: data) else {
            return RecordingStatus()
        }
        return status
    }

    static func write(_ status: RecordingStatus) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        defaults?.set(data, forKey: key)
    }
}

/// Widget and control kinds, shared so the app can reload them by name.
enum WidgetKinds {
    static let status = "PosXYStatus"
    static let recordingControl = "io.github.gravelcycles.posxy.control.recording"
    static let pauseControl = "io.github.gravelcycles.posxy.control.pause"
}
