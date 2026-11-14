import SwiftUI

/// Browse past days on the phone. Everything is drawn locally; no map tiles are fetched.
struct HistoryView: View {
    @EnvironmentObject private var recorder: LocationRecorder
    @State private var days: [String] = []

    var body: some View {
        List {
            ForEach(days, id: \.self) { key in
                NavigationLink {
                    DayView(dayKey: key)
                } label: {
                    Text(Self.title(for: key))
                }
            }
            .onDelete { offsets in
                for i in offsets {
                    PointStore.shared.delete(dayKey: days[i])
                    MotionStore.shared.delete(dayKey: days[i])
                    CorrectionStore.shared.delete(dayKey: days[i])
                }
                days.remove(atOffsets: offsets)
                recorder.refreshTodayCount()
                PlaceCache.shared.refresh(force: true)
            }
        }
        .overlay {
            if days.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "map",
                                       description: Text("Turn on recording and go for a walk."))
            }
        }
        .navigationTitle("History")
        .toolbar { EditButton() }
        .onAppear { days = PointStore.shared.dayKeys().reversed() }
    }

    static func title(for key: String) -> String {
        guard let date = PointStore.date(fromDayKey: key) else { return key }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }
}

struct DayView: View {
    @EnvironmentObject private var placeCache: PlaceCache
    let dayKey: String
    @State private var points: [TrackPoint] = []
    @State private var segments: [Segment] = []
    @State private var corrected: Set<Int> = []      // ids of segments with a manual correction
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                TrackSketch(points: points, segments: segments)
                    .frame(height: 300)
                    .listRowInsets(EdgeInsets())
            }
            Section("Summary") {
                ForEach(Segmenter.totals(segments).filter { $0.type != .unknown }) { t in
                    HStack {
                        Label(t.type.label, systemImage: t.type.symbol).foregroundStyle(t.type.color)
                        Spacer()
                        Text(t.type == .stationary ? Fmt.duration(t.duration)
                                                   : "\(Fmt.distance(t.distance)) · \(Fmt.duration(t.duration))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                LabeledContent("Points", value: "\(points.count)")
            }
            Section {
                ForEach(segments) { seg in
                    Menu {
                        Section("What was this?") {
                            ForEach(ActivityType.correctable, id: \.self) { type in
                                Button {
                                    correct(seg, to: type)
                                } label: {
                                    Label(type.label, systemImage: seg.type == type ? "checkmark" : type.symbol)
                                }
                            }
                        }
                        if corrected.contains(seg.id) {
                            Button("Back to automatic", systemImage: "arrow.uturn.backward") { resetCorrection(seg) }
                        }
                    } label: {
                        segmentRow(seg)
                    }
                    .tint(.primary)
                }
            } header: {
                Text("Timeline")
            } footer: {
                Text("Tap a trip to correct it, e.g. a drive that was really a train. Corrections stay on this iPhone and are included in exports.")
            }
        }
        .navigationTitle(HistoryView.title(for: dayKey))
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if !loaded { ProgressView() } }
        .task { await load() }
    }

    private func segmentRow(_ seg: Segment) -> some View {
                    HStack(spacing: 12) {
                        Image(systemName: seg.type.symbol)
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(seg.type.color))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                if let place = placeCache.place(for: seg, points: points), let name = place.name {
                                    Label(name, systemImage: place.symbol).font(.body.weight(.semibold))
                                } else {
                                    Text(seg.type.label).font(.body.weight(.semibold))
                                }
                                if corrected.contains(seg.id) {
                                    Image(systemName: "pencil.circle.fill").font(.caption).foregroundStyle(.secondary)
                                        .accessibilityLabel("Corrected by hand")
                                }
                            }
                            Text("\(seg.start.formatted(date: .omitted, time: .shortened)) – \(seg.end.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if seg.type != .stationary { Text(Fmt.distance(seg.distance)).monospacedDigit() }
                            Text(Fmt.duration(seg.duration)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
    }

    private func correct(_ seg: Segment, to type: ActivityType) {
        CorrectionStore.shared.set(type, from: seg.start, to: seg.end)
        Task { await load() }
    }

    private func resetCorrection(_ seg: Segment) {
        CorrectionStore.shared.reset(from: seg.start, to: seg.end)
        Task { await load() }
    }

    @MainActor
    private func load() async {
        let key = dayKey
        let result = await Task.detached(priority: .userInitiated) { () -> ([TrackPoint], [Segment], Set<Int>) in
            let pts = Segmenter.clean(PointStore.shared.points(dayKey: key))
            let auto = Segmenter.segments(pts, motion: MotionStore.shared.spans(dayKey: key))
            guard let first = pts.first, let last = pts.last else { return (pts, auto, []) }
            let fixes = CorrectionStore.shared.corrections(from: first.t, to: last.t.addingTimeInterval(1))
            let segs = Corrections.apply(fixes, to: auto)
            let marked = Set(segs.filter { CorrectionStore.shared.isCorrected(from: $0.start, to: $0.end) }.map(\.id))
            return (pts, segs, marked)
        }.value
        points = result.0
        segments = result.1
        corrected = result.2
        loaded = true
    }
}
