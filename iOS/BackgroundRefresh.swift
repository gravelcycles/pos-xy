import BackgroundTasks
import UIKit

/// Background app refresh: iOS wakes the app every so often (it decides when: typically every
/// 15 minutes to a few hours, more often for apps you use a lot), even after it killed the app for
/// memory, unless you swiped it away or turned Background App Refresh off for Pos XY. Each wake-up
/// restarts recording if it had stopped and saves one fix, so a kill costs at most until the next
/// wake-up instead of until you next move 150 m or open the app.
enum BackgroundRefresh {
    static var identifier: String { (Bundle.main.bundleIdentifier ?? "posxy") + ".refresh" }

    /// Call from application(_:didFinishLaunchingWithOptions:) (iOS requires registering before launch ends).
    static func register() {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            handle(task)
        }
        if !ok { Diagnostics.shared.log("refresh", "Couldn't register background refresh (identifier missing from Info.plist?).") }
    }

    /// Asks iOS for the next wake-up. Safe to call often; a newer request replaces the older one.
    static func schedule() {
        guard LocationRecorder.shared.isRecording else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Diagnostics.shared.log("refresh", "Couldn't schedule background refresh: \(error.localizedDescription) "
                                   + "(is Background App Refresh on for Pos XY?)")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()                                    // keep the chain going
        let status = UIApplication.shared.backgroundRefreshStatus == .available ? "" : " (refresh status not available)"
        Diagnostics.shared.log("refresh", "Woken by background app refresh\(status).")
        let work = Task { @MainActor in
            let recorder = LocationRecorder.shared    // creating it restarts recording if it's on
            if recorder.isRecording { _ = await recorder.recordNow(timeout: 20) }
            recorder.backfillMotion(reason: "background refresh")
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            Diagnostics.shared.log("refresh", "Background refresh ran out of time.")
            task.setTaskCompleted(success: false)
        }
    }
}
