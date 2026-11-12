import SwiftUI
import MapKit
import UniformTypeIdentifiers

struct ViewerView: View {
    @EnvironmentObject private var library: TrackLibrary
    @State private var selectedDay: Date?

    var body: some View {
        NavigationSplitView {
            DayList(selection: $selectedDay)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            if let day = selectedDay, library.days.contains(where: { $0.day == day }) {
                DayDetailView(day: day, data: library.dayData(for: day), dataID: library.version)
                    .id("\(day.timeIntervalSince1970)-\(library.version)")
            } else {
                EmptyStateView()
            }
        }
        .navigationTitle(selectedDay.map { $0.formatted(.dateTime.weekday(.wide).month(.wide).day().year()) } ?? "Pos XY")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { step(by: 1) } label: { Label("Previous day", systemImage: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .help("Previous day (⌘←)")
                Button { step(by: -1) } label: { Label("Next day", systemImage: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .help("Next day (⌘→)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { library.showImporter = true } label: { Label("Open", systemImage: "folder") }
                    .help("Open exports (⌘O)")
            }
        }
        .fileImporter(isPresented: $library.showImporter,
                      allowedContentTypes: [.posxyTrack, .json, .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.open(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            library.open(urls)
            return !urls.isEmpty
        }
        .sheet(item: Binding(get: { library.locked.first }, set: { _ in })) { file in
            PassphraseSheet(file: file)
                .environmentObject(library)
        }
        .alert("Couldn't open file",
               isPresented: Binding(get: { library.errorMessage != nil },
                                    set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        .onChange(of: library.days) { _, days in
            if let d = selectedDay, days.contains(where: { $0.day == d }) { return }
            selectedDay = days.first?.day
        }
    }

    /// +1 = older (the list is newest first).
    private func step(by delta: Int) {
        let days = library.days
        guard !days.isEmpty else { return }
        guard let current = selectedDay, let i = days.firstIndex(where: { $0.day == current }) else {
            selectedDay = days.first?.day
            return
        }
        let j = min(max(i + delta, 0), days.count - 1)
        selectedDay = days[j].day
    }
}

// MARK: - Sidebar

struct DayList: View {
    @EnvironmentObject private var library: TrackLibrary
    @Binding var selection: Date?

    var body: some View {
        List(selection: $selection) {
            ForEach(monthGroups) { group in
                Section(group.month.formatted(.dateTime.month(.wide).year())) {
                    ForEach(group.days) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                .font(.body.weight(.medium))
                            Text("\(d.pointCount) points")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(d.day)
                    }
                }
            }
        }
        .overlay {
            if library.days.isEmpty {
                Text("No data loaded").foregroundStyle(.secondary)
            }
        }
    }

    private struct MonthGroup: Identifiable {
        var id: Date { month }
        let month: Date
        let days: [DayInfo]
    }

    private var monthGroups: [MonthGroup] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: library.days) {
            cal.date(from: cal.dateComponents([.year, .month], from: $0.day)) ?? $0.day
        }
        return grouped.map { MonthGroup(month: $0.key, days: $0.value.sorted { $0.day > $1.day }) }
            .sorted { $0.month > $1.month }
    }
}

// MARK: - One day

struct DayDetailView: View {
    let day: Date
    let data: DayData
    let dataID: Int

    @State private var time: Date
    @State private var playing = false
    @State private var speed: Double = 300
    @State private var follow = false
    @State private var focus = MapFocus()

    init(day: Date, data: DayData, dataID: Int) {
        self.day = day
        self.data = data
        self.dataID = dataID
        // Start at the end of the day so the whole track is drawn in colour.
        _time = State(initialValue: data.points.last?.t ?? day)
    }

    private var points: [TrackPoint] { data.points }
    private var start: Date { points.first?.t ?? day }
    private var end: Date { points.last?.t ?? day }

    /// Index of the last point at or before `time`.
    private var cutoff: Int {
        var lo = 0, hi = points.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].t <= time { lo = mid + 1 } else { hi = mid }
        }
        return max(lo - 1, 0)
    }

    private var currentSegment: Segment? {
        let c = cutoff
        return data.segments.first { $0.first <= c && c < $0.last } ?? data.segments.last
    }

    /// Smoothly interpolated position at `time`.
    private var markerCoordinate: CLLocationCoordinate2D? {
        guard !points.isEmpty else { return nil }
        let i = cutoff
        let a = points[i]
        guard i + 1 < points.count else { return CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon) }
        let b = points[i + 1]
        let dt = b.t.timeIntervalSince(a.t)
        guard dt > 0, dt <= Segmenter.gapThreshold else {
            return CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon)
        }
        let f = min(max(time.timeIntervalSince(a.t) / dt, 0), 1)
        return CLLocationCoordinate2D(latitude: a.lat + (b.lat - a.lat) * f,
                                      longitude: a.lon + (b.lon - a.lon) * f)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TrackMapView(points: points,
                             segments: data.segments,
                             dataID: dataID,
                             cutoff: cutoff,
                             marker: markerCoordinate,
                             markerType: currentSegment?.type ?? .unknown,
                             follow: follow,
                             focus: focus)
                    .overlay(alignment: .bottomTrailing) { OSMAttribution() }
                    .overlay(alignment: .topLeading) { Legend().padding(10) }
                Divider()
                TimelineControls(start: start, end: end, segments: data.segments,
                                 time: $time, playing: $playing, speed: $speed, follow: $follow)
            }
            Divider()
            SegmentList(points: points, segments: data.segments, current: currentSegment) { seg in
                playing = false
                time = seg.start
                focus = MapFocus(id: focus.id + 1, first: seg.first, last: seg.last)
            } onShowDay: {
                focus = MapFocus(id: focus.id + 1)
            }
            .frame(width: 280)
        }
        .task(id: playing) {
            guard playing else { return }
            if time >= end { time = start }
            while !Task.isCancelled && playing {
                try? await Task.sleep(for: .milliseconds(33))
                let next = time.addingTimeInterval(speed / 30)
                if next >= end {
                    time = end
                    playing = false
                } else {
                    time = next
                }
            }
        }
    }
}

// MARK: - Timeline

struct TimelineControls: View {
    let start: Date
    let end: Date
    let segments: [Segment]
    @Binding var time: Date
    @Binding var playing: Bool
    @Binding var speed: Double
    @Binding var follow: Bool

    private var span: TimeInterval { max(end.timeIntervalSince(start), 1) }

    var body: some View {
        VStack(spacing: 8) {
            ActivityStrip(start: start, end: end, segments: segments, time: $time)
                .frame(height: 40)
            HStack(spacing: 12) {
                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Play / pause (space)")

                Text(time.formatted(.dateTime.hour().minute().second()))
                    .monospacedDigit()
                    .frame(width: 84, alignment: .leading)

                Slider(value: Binding(get: { time.timeIntervalSince(start) / span },
                                      set: { playing = false; time = start.addingTimeInterval($0 * span) }),
                       in: 0...1)

                Picker("Speed", selection: $speed) {
                    Text("1 min/s").tag(60.0)
                    Text("5 min/s").tag(300.0)
                    Text("15 min/s").tag(900.0)
                    Text("1 h/s").tag(3600.0)
                }
                .labelsHidden()
                .frame(width: 100)

                Toggle("Follow", isOn: $follow)
                    .toggleStyle(.checkbox)
                    .help("Keep the map centred on the marker")
            }
        }
        .padding(12)
    }
}

/// A 24h-style bar coloured by activity. Click or drag on it to scrub through the day.
struct ActivityStrip: View {
    let start: Date
    let end: Date
    let segments: [Segment]
    @Binding var time: Date

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let span = max(end.timeIntervalSince(start), 1)
            let barHeight = geo.size.height - 14
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let bar = CGRect(x: 0, y: 0, width: size.width, height: barHeight)
                    ctx.fill(Path(roundedRect: bar, cornerRadius: 4), with: .color(.secondary.opacity(0.15)))
                    for s in segments {
                        let x0 = s.start.timeIntervalSince(start) / span * size.width
                        let x1 = s.end.timeIntervalSince(start) / span * size.width
                        let rect = CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: barHeight)
                        ctx.fill(Path(rect), with: .color(s.type.color.opacity(s.type == .stationary ? 0.45 : 0.9)))
                    }
                    // Hour ticks + labels.
                    let cal = Calendar.current
                    let every = span > 10 * 3600 ? 3 : (span > 4 * 3600 ? 2 : 1)
                    guard var tick = cal.nextDate(after: start, matching: DateComponents(minute: 0, second: 0),
                                                  matchingPolicy: .nextTime) else { return }
                    while tick < end {
                        let x = tick.timeIntervalSince(start) / span * size.width
                        ctx.fill(Path(CGRect(x: x, y: barHeight - 5, width: 1, height: 5)),
                                 with: .color(.primary.opacity(0.35)))
                        if cal.component(.hour, from: tick) % every == 0 {
                            ctx.draw(Text(tick.formatted(.dateTime.hour()))
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary),
                                     at: CGPoint(x: x, y: barHeight + 7))
                        }
                        tick = tick.addingTimeInterval(3600)
                    }
                }
                // Playhead.
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.primary)
                    .frame(width: 3, height: barHeight + 6)
                    .offset(x: CGFloat(time.timeIntervalSince(start) / span) * width - 1.5, y: -3)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let f = min(max(value.location.x / max(width, 1), 0), 1)
                time = start.addingTimeInterval(Double(f) * span)
            })
        }
    }
}

// MARK: - Segment list

struct SegmentList: View {
    let points: [TrackPoint]
    let segments: [Segment]
    let current: Segment?
    let onSelect: (Segment) -> Void
    let onShowDay: () -> Void

    var body: some View {
        List {
            Section {
                let totals = Segmenter.totals(segments).filter { $0.type != .unknown }
                ForEach(totals) { t in
                    HStack {
                        Label(t.type.label, systemImage: t.type.symbol)
                            .foregroundStyle(t.type.color)
                        Spacer()
                        Text(t.type == .stationary ? Fmt.duration(t.duration)
                                                   : "\(Fmt.distance(t.distance)) · \(Fmt.duration(t.duration))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Button("Show whole day", action: onShowDay)
                    .buttonStyle(.link)
            } header: {
                Text("\(points.count) points")
            }

            Section("Timeline") {
                ForEach(segments) { seg in
                    SegmentRow(segment: seg, isCurrent: seg == current)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(seg) }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct SegmentRow: View {
    let segment: Segment
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: segment.type.symbol)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(segment.type.color))
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.type.label).font(.body.weight(.semibold))
                Text("\(segment.start.formatted(date: .omitted, time: .shortened)) – \(segment.end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if segment.type != .stationary {
                    Text(Fmt.distance(segment.distance)).monospacedDigit()
                }
                Text(Fmt.duration(segment.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? Color.accentColor.opacity(0.18) : .clear))
    }
}

// MARK: - Small pieces

struct OSMAttribution: View {
    var body: some View {
        Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .padding(6)
    }
}

struct Legend: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach([ActivityType.walking, .running, .cycling, .driving, .flying, .stationary], id: \.self) { t in
                HStack(spacing: 4) {
                    Circle().fill(t.color).frame(width: 8, height: 8)
                    Text(t.label).font(.caption)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
    }
}

struct EmptyStateView: View {
    @EnvironmentObject private var library: TrackLibrary

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "map")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Open a Pos XY export").font(.title2.weight(.semibold))
            Text("AirDrop a file from the iPhone app (it lands in Downloads), then drag it here, double-click it, or press ⌘O. Open several files at once to merge them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Button("Open…") { library.showImporter = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Text("Your history stays in memory only. Quitting the viewer forgets it.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PassphraseSheet: View {
    @EnvironmentObject private var library: TrackLibrary
    let file: LockedFile
    @State private var passphrase = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("“\(file.name)” is locked", systemImage: "lock.fill")
                .font(.headline)
            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit(unlock)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Skip") { library.skip(file) }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .interactiveDismissDisabled()
    }

    private func unlock() {
        guard !passphrase.isEmpty else { return }
        do {
            try library.unlock(file, passphrase: passphrase)
        } catch {
            self.error = error.localizedDescription
            passphrase = ""
        }
    }
}
