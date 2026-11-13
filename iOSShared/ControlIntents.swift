import AppIntents
import Foundation

// Intents behind the Control Center / Lock Screen / Action button controls and the interactive
// Home Screen widget. They're compiled into both the app and the widget extension.
//
// Conforming to LiveActivityIntent makes iOS run `perform()` in the app's process (launching it
// in the background if needed), which is where the location manager lives. The widget extension
// only needs the types to exist, so the work is compiled out there (WIDGET_EXTENSION is set in
// the PosXYWidgets target). Apple's WWDC24 timer control uses the same SetValueIntent +
// LiveActivityIntent pairing.

struct SetRecordingIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Record My Location"
    static let description = IntentDescription("Turns Pos XY location recording on or off.")
    // The Start/Stop shortcuts already cover this in the Shortcuts app.
    static let isDiscoverable = false

    @Parameter(title: "Recording")
    var value: Bool

    init() {}
    init(value: Bool) { self.value = value }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let recorder = LocationRecorder.shared
        if value {
            if recorder.isPaused { recorder.resume() }
            if !recorder.isRecording { recorder.start() }
        } else if recorder.isRecording {
            recorder.stop()
        }
        #endif
        return .result()
    }
}

struct SetPausedIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Pause Recording for an Hour"
    static let description = IntentDescription("Pauses Pos XY for an hour, or resumes it if it's paused.")
    static let isDiscoverable = false

    @Parameter(title: "Paused")
    var value: Bool

    init() {}
    init(value: Bool) { self.value = value }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let recorder = LocationRecorder.shared
        if value {
            // Pausing only makes sense while recording; otherwise the control just flips back.
            if recorder.isRecording { recorder.pause(until: Date().addingTimeInterval(3600)) }
            else { WidgetSync.publish(recorder.widgetStatus, force: true) }
        } else {
            recorder.resume()
        }
        #endif
        return .result()
    }
}
