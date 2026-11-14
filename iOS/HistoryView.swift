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
            Section("Timeline") {
                ForEach(segments) { seg in
                    HStack(spacing: 12) {
                        Image(systemName: seg.type.symbol)
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(seg.type.color))
                        VStack(alignment: .leading, spacing: 2) {
                            if let place = placeCache.place(for: seg, points: points), let name = place.name {
                                Label(name, systemImage: place.symbol).font(.body.weight(.semibold))
                            } else {
                                Text(seg.type.label).font(.body.weight(.semibold))
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
                }
            }
        }
        .navigationTitle(HistoryView.title(for: dayKey))
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if !loaded { ProgressView() } }
        .task { await load() }
    }

    @MainActor
    private func load() async {
        let key = dayKey
        let result = await Task.detached(priority: .userInitiated) { () -> ([TrackPoint], [Segment]) in
            let pts = Segmenter.clean(PointStore.shared.points(dayKey: key))
            return (pts, Segmenter.segments(pts, motion: MotionStore.shared.spans(dayKey: key)))
        }.value
        points = result.0
        segments = result.1
        loaded = true
    }
}
