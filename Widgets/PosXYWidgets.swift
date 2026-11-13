import AppIntents
import SwiftUI
import WidgetKit

/// Lock Screen / Home Screen status widget plus Control Center, Lock Screen and Action button
/// controls. Everything here reads `RecordingStatus` from the shared keychain item; the controls' intents
/// run in the app (see iOSShared/ControlIntents.swift). No networking, like the rest of Pos XY.
@main
struct PosXYWidgets: WidgetBundle {
    var body: some Widget {
        RecordingStatusWidget()
        RecordingControl()
        PauseControl()
    }
}

// MARK: - Controls (iOS 18: Control Center, Lock Screen buttons, Action button)

struct RecordingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKinds.recordingControl, provider: Provider()) { isOn in
            ControlWidgetToggle("Record Location", isOn: isOn, action: SetRecordingIntent()) { on in
                Label(on ? "Recording" : "Off", systemImage: on ? "location.fill" : "location.slash")
            }
            .tint(.green)
        }
        .displayName("Record Location")
        .description("Turn Pos XY location recording on or off.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { true }
        func currentValue() async throws -> Bool { SharedStatusStore.read().isRecording }
    }
}

struct PauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetKinds.pauseControl, provider: Provider()) { isPaused in
            ControlWidgetToggle("Pause Pos XY", isOn: isPaused, action: SetPausedIntent()) { paused in
                Label(paused ? "Paused" : "Pause 1 h", systemImage: paused ? "pause.circle.fill" : "pause.circle")
            }
            .tint(.orange)
        }
        .displayName("Pause for 1 Hour")
        .description("Pause Pos XY for an hour. Tap again to resume.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }
        func currentValue() async throws -> Bool { SharedStatusStore.read().isPaused() }
    }
}

// MARK: - Status widget (Lock Screen + Home Screen)

struct StatusEntry: TimelineEntry {
    let date: Date
    let status: RecordingStatus
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), status: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), status: context.isPreview ? .preview : SharedStatusStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let now = Date()
        let status = SharedStatusStore.read()
        // Redraw when a pause ends and when the day's count resets at midnight, without the app.
        var dates = [now, Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))]
        if let until = status.pausedUntil, until > now { dates.append(until) }
        let entries = dates.sorted().map { StatusEntry(date: $0, status: status) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct RecordingStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.status, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Recording Status")
        .description("Whether Pos XY is recording, and how many points it took today.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .systemSmall])
    }
}

private enum RecState {
    case recording, paused(until: Date), off

    init(_ s: RecordingStatus, at date: Date) {
        if !s.isRecording { self = .off }
        else if s.isPaused(at: date), let until = s.pausedUntil { self = .paused(until: until) }
        else { self = .recording }
    }

    var symbol: String {
        switch self {
        case .recording: return "location.fill"
        case .paused: return "pause.circle.fill"
        case .off: return "location.slash"
        }
    }

    var title: String {
        switch self {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .off: return "Off"
        }
    }

    var tint: Color {
        switch self {
        case .recording: return .green
        case .paused: return .orange
        case .off: return .secondary
        }
    }
}

struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    private var state: RecState { RecState(entry.status, at: entry.date) }
    private var points: Int { entry.status.points(on: entry.date) }
    private var isOn: Bool { entry.status.isRecording }

    var body: some View {
        content
            .containerBackground(for: .widget) {
                if family == .systemSmall {
                    LinearGradient(colors: [Color(red: 0.07, green: 0.13, blue: 0.29),
                                            Color(red: 0.15, green: 0.28, blue: 0.50)],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    Color.clear
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: small
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: state.symbol).font(.system(size: 17, weight: .semibold))
                if isOn {
                    Text(points, format: .number.notation(.compactName))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .widgetAccentable()
        .accessibilityLabel("Pos XY \(state.title), \(points) points today")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Pos XY", systemImage: state.symbol)
                .font(.headline)
                .widgetAccentable()
            switch state {
            case .recording:
                Text("Recording · \(points) pts")
            case .paused(let until):
                Text("Paused until \(until, style: .time)")
            case .off:
                Text("Not recording")
            }
            if isOn, let last = entry.status.lastFix {
                Text("Fix \(last, style: .relative) ago")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        switch state {
        case .recording: return Label("Pos XY · \(points) pts", systemImage: state.symbol)
        case .paused: return Label("Pos XY paused", systemImage: state.symbol)
        case .off: return Label("Pos XY off", systemImage: state.symbol)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: state.symbol).foregroundStyle(state.tint)
                Text(state.title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            Spacer(minLength: 4)
            Text(points, format: .number)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 6)
            Button(intent: SetRecordingIntent(value: !isOn)) {
                Label(isOn ? "Stop" : "Record", systemImage: isOn ? "stop.fill" : "record.circle")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(isOn ? .white : .green)
        }
        .foregroundStyle(.white)
    }

    private var subtitle: String {
        if case .paused(let until) = state {
            return "paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return "points today"
    }
}
