import AppIntents

// Siri & Shortcuts actions. They make automations possible, e.g. "When I connect to CarPlay → Start
// Recording", or "When I arrive at the clinic → Pause Recording". They run on-device like the rest.

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Starts recording your location in Pos XY.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recorder = LocationRecorder.shared
        if recorder.isPaused { recorder.resume() }
        if !recorder.isRecording { recorder.start() }
        return .result(dialog: "Pos XY is recording.")
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops recording your location in Pos XY.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        LocationRecorder.shared.stop()
        return .result(dialog: "Pos XY stopped recording.")
    }
}

struct PauseRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Recording"
    static let description = IntentDescription("Pauses Pos XY for a number of hours, then it resumes by itself.")

    @Parameter(title: "Hours", default: 1)
    var hours: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let h = min(max(hours, 1), 72)
        LocationRecorder.shared.pause(until: Date().addingTimeInterval(TimeInterval(h) * 3600))
        return .result(dialog: "Pos XY is paused for \(h) hour\(h == 1 ? "" : "s").")
    }
}

/// For Shortcuts automations that wake Pos XY at moments you're likely to move: connecting to
/// CarPlay or the car's Bluetooth, leaving Wi-Fi, unplugging the charger, set times of day.
/// Each run saves a fix and, if recording is on, restarts continuous recording (even if iOS had
/// killed the app), so the trip that follows gets recorded.
struct RecordLocationNowIntent: AppIntent {
    static let title: LocalizedStringResource = "Record Location Now"
    static let description = IntentDescription("Saves your current location in Pos XY and makes sure recording is running. Use it in automations, e.g. when connecting to CarPlay.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recorder = LocationRecorder.shared
        if recorder.isPaused { return .result(dialog: "Pos XY is paused, so nothing was saved.") }
        guard let fix = await recorder.recordNow() else {
            return .result(dialog: "Pos XY couldn't get a GPS fix.")
        }
        return .result(dialog: "Saved your location (±\(Int(fix.horizontalAccuracy)) m).")
    }
}

struct PosXYShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Start recording in \(.applicationName)", "Start \(.applicationName)"],
                    shortTitle: "Start Recording", systemImageName: "location.fill")
        AppShortcut(intent: StopRecordingIntent(),
                    phrases: ["Stop recording in \(.applicationName)", "Stop \(.applicationName)"],
                    shortTitle: "Stop Recording", systemImageName: "location.slash")
        AppShortcut(intent: PauseRecordingIntent(),
                    phrases: ["Pause \(.applicationName)"],
                    shortTitle: "Pause Recording", systemImageName: "pause.circle")
        AppShortcut(intent: RecordLocationNowIntent(),
                    phrases: ["Record my location in \(.applicationName)", "Save location in \(.applicationName)"],
                    shortTitle: "Record Location Now", systemImageName: "mappin.and.ellipse")
    }
}
