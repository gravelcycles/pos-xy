import Foundation
import WidgetKit

/// Publishes the recorder's status to the App Group and asks iOS to redraw the Lock Screen
/// widgets and Control Center controls.
///
/// State changes (start, stop, pause, resume) are written and reloaded right away. New points
/// are written at most once a minute and reloaded at most every 15 minutes: iOS rations
/// background widget reloads, and the widget's "last fix" time is a self-updating relative date.
enum WidgetSync {
    private static var lastWrite = Date.distantPast
    private static var lastReload = Date.distantPast
    private static var lastPublished: RecordingStatus?

    /// Call on the main thread (where the recorder lives). Takes the status rather than reading
    /// `LocationRecorder.shared`, because the recorder publishes from its own initializer.
    static func publish(_ status: RecordingStatus, force: Bool) {
        let now = Date()
        guard force || (status != lastPublished && now.timeIntervalSince(lastWrite) >= 60) else { return }
        lastPublished = status
        lastWrite = now
        SharedStatusStore.write(status)

        guard force || now.timeIntervalSince(lastReload) > 15 * 60 else { return }
        lastReload = now
        Task { @MainActor in
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.status)
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(ofKind: WidgetKinds.recordingControl)
                ControlCenter.shared.reloadControls(ofKind: WidgetKinds.pauseControl)
            }
        }
    }
}
