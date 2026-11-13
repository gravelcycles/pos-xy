import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // When iOS relaunches us in the background for a location event, this restarts recording.
        _ = LocationRecorder.shared
        ExportView.removeOldExports()
        return true
    }
}

@main
struct PosXYApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = LocationRecorder.shared
    @StateObject private var lock = AppLock()
    @StateObject private var placeCache = PlaceCache.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(recorder)
                .environmentObject(lock)
                .environmentObject(placeCache)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var recorder: LocationRecorder
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            ContentView()
            if lock.isLocked { LockedView() }
        }
        .onAppear { lock.unlockIfPending() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: lock.lockIfEnabled()
            case .active:
                recorder.refreshTodayCount()
                PlaceCache.shared.refresh()
                lock.unlockIfPending()
            default: break
            }
        }
    }
}
