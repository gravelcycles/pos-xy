import Foundation
import Security

/// The small slice of recorder state that the Lock Screen widgets and the Control Center
/// controls display. The app writes it to a keychain item in a shared access group; the widget
/// extension only reads it.
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

/// Storage shared by the app and the widget extension: one keychain item in a shared access group.
///
/// Why the keychain and not an App Group: a free Apple ID can't register App Group IDs from the
/// command line, but every provisioning profile (free or paid) already allows `TEAMID.*` keychain
/// groups, so this needs no developer-portal setup. The item never leaves the device
/// (`ThisDeviceOnly`) and is readable after first unlock, so Lock Screen widgets can draw it.
enum SharedStatusStore {
    /// `$(AppIdentifierPrefix)$(APP_BUNDLE_ID).shared`, expanded into both Info.plists at build time
    /// and listed in both targets' `keychain-access-groups` entitlement.
    static let accessGroup: String? = {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "PosXYKeychainGroup") as? String,
              !group.isEmpty, !group.hasPrefix(".") else { return nil }  // "." = built without a team
        return group
    }()

    private static var itemQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "PosXYWidgetStatus",
            kSecAttrAccount as String: "recordingStatus.v1",
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    static func read() -> RecordingStatus {
        var query = itemQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let status = try? JSONDecoder().decode(RecordingStatus.self, from: data) else {
            return RecordingStatus()
        }
        return status
    }

    static func write(_ status: RecordingStatus) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        let update = [kSecValueData as String: data] as CFDictionary
        if SecItemUpdate(itemQuery as CFDictionary, update) == errSecItemNotFound {
            var add = itemQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// Widget and control kinds, shared so the app can reload them by name.
enum WidgetKinds {
    static let status = "PosXYStatus"
    static let recordingControl = "io.github.gravelcycles.posxy.control.recording"
    static let pauseControl = "io.github.gravelcycles.posxy.control.pause"
}
