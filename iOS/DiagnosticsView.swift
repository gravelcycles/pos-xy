import SwiftUI
import CoreLocation
import UIKit

/// Health check for background recording + the on-device diagnostics log (no coordinates).
struct DiagnosticsView: View {
    @EnvironmentObject private var recorder: LocationRecorder
    @ObservedObject private var diag = Diagnostics.shared
    @State private var exportURL: URL?
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                check(ok: recorder.authorization == .authorizedAlways,
                      title: "Location permission",
                      value: LocationRecorder.describe(recorder.authorization),
                      help: recorder.authorization == .authorizedAlways ? nil
                        : "With anything but Always, iOS stops recording soon after you leave the app and never restarts it. Settings → Pos XY → Location → Always.")
                check(ok: recorder.preciseAllowed, title: "Precise Location", value: recorder.preciseAllowed ? "On" : "Off",
                      help: recorder.preciseAllowed ? nil : "Without it every fix is kilometres off and Pos XY throws it away.")
                check(ok: recorder.isRecording, title: "Recording", value: recorder.isRecording ? "On" : "Off", help: nil)
                LabeledContent("Mode", value: LocationRecorder.describe(interval: recorder.interval)
                               + (recorder.interval == 0 ? " · \(recorder.powerMode.title)" : ""))
                LabeledContent("Blue location pill", value: recorder.authorization == .authorizedAlways
                               ? "Off" : "On (iOS requires it with While Using)")
                LabeledContent("Low Power Mode", value: ProcessInfo.processInfo.isLowPowerModeEnabled ? "On" : "Off")
                LabeledContent("This launch", value: diag.launchedByLocationEvent ? "By iOS, in the background" : "Normal")
                if let last = diag.previousLastAlive {
                    LabeledContent("Previous run") {
                        Text(diag.previousEndedCleanly ? "Ended cleanly"
                             : "Stopped without warning, \(Diagnostics.duration(Date().timeIntervalSince(last))) ago")
                            .foregroundStyle(diag.previousEndedCleanly ? Color.secondary : Color.orange)
                    }
                }
                if recorder.authorization != .authorizedAlways || !recorder.preciseAllowed {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            } header: {
                Text("Background recording check")
            } footer: {
                Text("Don't swipe Pos XY away in the app switcher; that stops recording until you open it again.")
            }

            Section {
                if let url = exportURL {
                    ShareLink(item: url) {
                        Label("Share log (last 7 days)…", systemImage: "square.and.arrow.up")
                    }
                }
                Button("Clear log", role: .destructive) { confirmClear = true }
            } footer: {
                Text("The log records launches, permission changes, GPS deliveries, gaps and drops, but never your location, so it's safe to send for debugging. Kept for 14 days on this iPhone.")
            }

            Section("Recent events (newest first)") {
                ForEach(diag.recent.reversed()) { e in
                    Text(e.line)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .onAppear { recorder.flushStats(); exportURL = diag.makeExport() }
        .confirmationDialog("Clear the diagnostics log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { diag.clear(); exportURL = diag.makeExport() }
        }
    }

    private func check(ok: Bool, title: String, value: String, help: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? Color.green : Color.orange)
                Text(title)
                Spacer()
                Text(value).foregroundStyle(.secondary)
            }
            if let help {
                Text(help).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
