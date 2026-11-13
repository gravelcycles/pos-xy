import SwiftUI
import LocalAuthentication

/// Optional Face ID / passcode lock for the app's UI. (Recording keeps running while locked.)
final class AppLock: ObservableObject {
    private static let key = "lock.enabled"

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.key) }
    }
    @Published private(set) var isLocked: Bool
    private var pendingAutoUnlock: Bool
    private var authenticating = false

    init() {
        let on = UserDefaults.standard.bool(forKey: Self.key)
        enabled = on
        isLocked = on
        pendingAutoUnlock = on
    }

    func lockIfEnabled() {
        guard enabled else { return }
        isLocked = true
        pendingAutoUnlock = true
    }

    /// Prompts once after returning from the background (not again if the user cancels).
    func unlockIfPending() {
        guard isLocked, pendingAutoUnlock else { return }
        pendingAutoUnlock = false
        unlock()
    }

    func unlock() {
        guard isLocked, !authenticating else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false   // no passcode set on the device: nothing to check against
            return
        }
        authenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "Unlock your location history") { success, _ in
            DispatchQueue.main.async {
                self.authenticating = false
                if success { self.isLocked = false }
            }
        }
    }
}

struct LockedView: View {
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.system(size: 44))
                Text("Pos XY is locked").font(.headline)
                Text("Recording continues in the background.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Unlock") { lock.unlock() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
