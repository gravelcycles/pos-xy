import SwiftUI
import CoreLocation
import UIKit

struct ContentView: View {
    @EnvironmentObject private var recorder: LocationRecorder
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var placeCache: PlaceCache
    @State private var todayPoints: [TrackPoint] = []
    @State private var todaySegments: [Segment] = []
    @State private var confirmDelete = false
    @State private var storageBytes = 0
    @State private var dayCount = 0

    var body: some View {
        NavigationStack {
            List {
                recordingSection
                todaySection
                FrequencySection()
                Section {
                    NavigationLink {
                        HistoryView()
                    } label: {
                        Label("History", systemImage: "calendar")
                    }
                    NavigationLink {
                        ExportView()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Export & AirDrop to Mac", systemImage: "square.and.arrow.up")
                            if let last = ExportView.lastExport {
                                Text("Last export \(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: Date()))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                privacySection
            }
            .navigationTitle("Pos XY")
            .task(id: recorder.todayCount / 5) { await reloadToday() }
            .task { placeCache.refresh() }
        }
    }

    // MARK: Sections

    private var recordingSection: some View {
        Section {
            Toggle(isOn: Binding(get: { recorder.isRecording },
                                 set: { $0 ? recorder.start() : recorder.stop() })) {
                Label("Record my location", systemImage: recorder.isRecording ? "location.fill" : "location.slash")
            }
            if let warning = authWarning {
                VStack(alignment: .leading, spacing: 6) {
                    Text(warning).font(.callout)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                .foregroundStyle(.orange)
            }
            if recorder.isRecording, let until = recorder.pausedUntil, until > Date() {
                HStack {
                    Label {
                        Text("Paused until \(until.formatted(date: until.timeIntervalSinceNow > 20 * 3600 ? .abbreviated : .omitted, time: .shortened))")
                    } icon: {
                        Image(systemName: "pause.circle.fill")
                    }
                    .foregroundStyle(.orange)
                    Spacer()
                    Button("Resume") { recorder.resume() }
                        .buttonStyle(.bordered)
                }
            } else if recorder.isRecording {
                Menu {
                    Button("For 1 hour") { recorder.pause(until: Date().addingTimeInterval(3600)) }
                    Button("For 4 hours") { recorder.pause(until: Date().addingTimeInterval(4 * 3600)) }
                    Button("Until tomorrow morning") { recorder.pause(until: LocationRecorder.tomorrowMorning()) }
                } label: {
                    Label("Pause recording…", systemImage: "pause.circle")
                }
            }
            if recorder.isRecording {
                LabeledContent("Points today", value: "\(recorder.todayCount)")
                if let p = recorder.lastPoint {
                    LabeledContent("Last fix") {
                        Text(p.t, style: .time)
                    }
                    if let acc = p.acc {
                        LabeledContent("Accuracy", value: "±\(Int(acc)) m")
                    }
                }
                HStack {
                    Text("Activity")
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: recorder.currentActivity.symbol)
                        Text(recorder.currentActivity.label)
                    }
                    .foregroundStyle(recorder.currentActivity == .unknown ? Color.secondary : recorder.currentActivity.color)
                }
                if recorder.interval > 0 {
                    LabeledContent("Next point") {
                        if recorder.isTakingPoint {
                            Text("Getting a GPS fix…")
                        } else if let next = recorder.nextPointAt {
                            Text(next, style: .relative)
                        }
                    }
                }
                if recorder.isLowPower {
                    Label("Standing still: GPS resting", systemImage: "leaf")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("GPS works without a network, so this keeps recording in airplane mode. On flights, sit by the window for the best fixes.")
        }
    }

    private var todaySection: some View {
        Section("Today") {
            TrackSketch(points: todayPoints, segments: todaySegments)
                .frame(height: 220)
                .listRowInsets(EdgeInsets())
            let stops = todaySegments.compactMap { placeCache.place(for: $0, points: todayPoints)?.name }
                .reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
            if !stops.isEmpty {
                Text(stops.joined(separator: " → "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            let totals = Segmenter.totals(todaySegments).filter { $0.type != .stationary && $0.type != .unknown }
            ForEach(totals) { t in
                HStack {
                    Label(t.type.label, systemImage: t.type.symbol).foregroundStyle(t.type.color)
                    Spacer()
                    Text("\(Fmt.distance(t.distance)) · \(Fmt.duration(t.duration))")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private var privacySection: some View {
        Section {
            Toggle(isOn: $lock.enabled) {
                Label("Require Face ID", systemImage: "faceid")
            }
            LabeledContent("Stored on this iPhone", value: "\(dayCount) days · \(ByteCountFormatter.string(fromByteCount: Int64(storageBytes), countStyle: .file))")
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete all history", systemImage: "trash")
            }
            .confirmationDialog("Delete all recorded locations from this iPhone?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    PointStore.shared.deleteAll()
                    recorder.refreshTodayCount()
                    placeCache.refresh(force: true)
                    Task { await reloadToday() }
                }
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("This app never uses the network. History stays on this iPhone, encrypted by iOS Data Protection and excluded from iCloud backups. It only leaves when you export it.")
        }
    }

    private var authWarning: String? {
        guard recorder.isRecording else { return nil }
        switch recorder.authorization {
        case .denied, .restricted:
            return "Location access is off for Pos XY."
        case .authorizedWhenInUse:
            return "Set Location to \"Always\" so recording continues when the app is closed."
        default:
            return recorder.preciseAllowed ? nil : "Turn on Precise Location for usable tracks."
        }
    }

    // MARK: Data

    @MainActor
    private func reloadToday() async {
        let key = PointStore.dayKey(Date())
        let result = await Task.detached(priority: .utility) { () -> ([TrackPoint], [Segment], Int, Int) in
            let store = PointStore.shared
            let pts = Segmenter.clean(store.points(dayKey: key))
            return (pts, Segmenter.segments(pts), store.totalBytes(), store.dayKeys().count)
        }.value
        todayPoints = result.0
        todaySegments = result.1
        storageBytes = result.2
        dayCount = result.3
    }
}
