import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// Locked export from the iPhone app (`.pxy`). Declared in Config/Mac-Info.plist.
    static let posxyTrack = UTType(exportedAs: "io.github.gravelcycles.posxy.track")
}

final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
    /// Double-clicking a .pxy file in Finder (e.g. straight from Downloads after AirDrop).
    func application(_ application: NSApplication, open urls: [URL]) {
        TrackLibrary.shared.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PosXYViewerApp: App {
    @NSApplicationDelegateAdaptor(ViewerAppDelegate.self) private var appDelegate
    @StateObject private var library = TrackLibrary.shared

    var body: some Scene {
        Window("Pos XY", id: "main") {
            ViewerView()
                .environmentObject(library)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { library.showImporter = true }
                    .keyboardShortcut("o")
                Button("Close All Data") { library.clear() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
    }
}
