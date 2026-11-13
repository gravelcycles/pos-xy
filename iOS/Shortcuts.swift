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
    }
}
