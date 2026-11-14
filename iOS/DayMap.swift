import SwiftUI
import UIKit

/// Where the map looks: centre in Web Mercator world units (0…1) and a continuous zoom.
struct MapCamera: Equatable {
    var x: Double
    var y: Double
    var zoom: Double

    static let minZoom = 1.0
    static let maxZoom = 19.5

    func worldSize() -> Double { 256 * pow(2, zoom) }

    func screen(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let ws = worldSize()
        return CGPoint(x: (Double(p.x) - x) * ws + Double(size.width) / 2,
                       y: (Double(p.y) - y) * ws + Double(size.height) / 2)
    }

    func world(at s: CGPoint, in size: CGSize) -> CGPoint {
        let ws = worldSize()
        return CGPoint(x: x + (Double(s.x) - Double(size.width) / 2) / ws,
                       y: y + (Double(s.y) - Double(size.height) / 2) / ws)
    }

    func clamped() -> MapCamera {
        MapCamera(x: min(max(x, 0), 1), y: min(max(y, 0), 1),
                  zoom: min(max(zoom, Self.minZoom), Self.maxZoom))
    }
}

/// A day's points and segments, pre-projected for the map.
struct DayMapData {
    let points: [TrackPoint]
    let segments: [Segment]
    let world: [CGPoint]

    static let empty = DayMapData(points: [], segments: [])

    init(points: [TrackPoint], segments: [Segment]) {
        self.points = points
        self.segments = segments
        world = points.map { p in
            let w = WebMercator.world(lat: p.lat, lon: p.lon)
            return CGPoint(x: w.x, y: w.y)
        }
    }

    /// Camera that shows `range` (default: the whole day) inside `size`, leaving `inset` points free.
    func fit(size: CGSize, inset: Double = 24, range: ClosedRange<Int>? = nil, maxZoom: Double = 17) -> MapCamera {
        guard !world.isEmpty else { return MapCamera(x: 0.5, y: 0.5, zoom: 1) }
        let lower = max(0, min(range?.lowerBound ?? 0, world.count - 1))
        let upper = max(lower, min(range?.upperBound ?? world.count - 1, world.count - 1))
        let r = lower...upper
        var lo = world[r.lowerBound], hi = lo
        for p in world[r] {
            lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y)
            hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y)
        }
        let z = WebMercator.fitZoom(w: Double(hi.x - lo.x), h: Double(hi.y - lo.y),
                                    width: max(Double(size.width) - 2 * inset, 1),
                                    height: max(Double(size.height) - 2 * inset, 1))
        return MapCamera(x: Double(lo.x + hi.x) / 2, y: Double(lo.y + hi.y) / 2,
                         zoom: min(z, maxZoom)).clamped()
    }

    func segment(at index: Int) -> Segment? {
        segments.first { $0.first <= index && index <= $0.last }
    }
}

// MARK: - Drawing

/// Draws OSM tiles (or a plain grid when tiles are off / offline) with the day's track on top.
struct DayMapCanvas: View {
    let data: DayMapData
    let camera: MapCamera
    /// Points after this index are drawn faded (time scrubber).
    var cutoff: Int?
    /// Index of a point to mark with a dot. Without one, the day's last point is marked.
    var marker: Int?
    var showsLastPoint = true

    @ObservedObject private var images = TileImages.shared
    @ObservedObject private var settings = MapSettings.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tilesOn = settings.tilesOn
        let maxTileZoom = settings.detail.maxZoom
        let dark = scheme == .dark
        let version = images.version
        Canvas { ctx, size in
            _ = version             // redraw when tiles arrive
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(dark ? Color(white: 0.13) : Color(white: 0.95)))
            drawGrid(&ctx, size)
            if tilesOn {
                drawTiles(&ctx, size, maxTileZoom: maxTileZoom)
                if dark { ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.28))) }
            }
            drawTrack(&ctx, size)
        }
    }

    private func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        var grid = Path()
        stride(from: 0, through: size.width, by: 24).forEach { x in
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        stride(from: 0, through: size.height, by: 24).forEach { y in
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(grid, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
    }

    private func drawTiles(_ ctx: inout GraphicsContext, _ size: CGSize, maxTileZoom: Int) {
        let tz = max(0, min(Int(camera.zoom.rounded()), maxTileZoom))
        let n = 1 << tz
        let ws = camera.worldSize()
        let tile = ws / Double(n)
        guard tile >= 16 else { return }
        let halfW = Double(size.width) / 2 / ws, halfH = Double(size.height) / 2 / ws
        let x0 = max(0, Int(floor((camera.x - halfW) * Double(n))))
        let x1 = min(n - 1, Int(floor((camera.x + halfW) * Double(n))))
        let y0 = max(0, Int(floor((camera.y - halfH) * Double(n))))
        let y1 = min(n - 1, Int(floor((camera.y + halfH) * Double(n))))
        guard x0 <= x1, y0 <= y1, (x1 - x0 + 1) * (y1 - y0 + 1) <= 150 else { return }
        for ty in y0...y1 {
            for tx in x0...x1 {
                let origin = camera.screen(CGPoint(x: Double(tx) / Double(n), y: Double(ty) / Double(n)), in: size)
                // Overlap by half a point to hide seams between tiles.
                let rect = CGRect(x: origin.x, y: origin.y, width: tile + 0.5, height: tile + 0.5)
                let key = TileKey(z: tz, x: tx, y: ty)
                if let img = images.image(key) {
                    ctx.draw(Image(uiImage: img), in: rect)
                    continue
                }
                images.request(key)
                // Meanwhile, enlarge a coarser tile we already have.
                for d in 1...min(4, max(1, tz)) where tz - d >= 0 {
                    let parent = TileKey(z: tz - d, x: tx >> d, y: ty >> d)
                    guard let img = images.image(parent), let cg = img.cgImage else { continue }
                    let sub = Double(cg.width) / Double(1 << d)
                    let crop = CGRect(x: Double(tx - (parent.x << d)) * sub, y: Double(ty - (parent.y << d)) * sub,
                                      width: sub, height: sub)
                    if let part = cg.cropping(to: crop) {
                        ctx.draw(Image(decorative: part, scale: 1), in: rect)
                    }
                    break
                }
            }
        }
    }

    private func drawTrack(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let pts = data.world.map { camera.screen($0, in: size) }
        guard !pts.isEmpty else { return }
        let cut = cutoff ?? Int.max

        func path(_ r: ClosedRange<Int>) -> Path {
            var p = Path()
            p.move(to: pts[r.lowerBound])
            for i in r.dropFirst() { p.addLine(to: pts[i]) }
            return p
        }
        // White casing first so lines read on top of busy map tiles.
        let casing = StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round)
        if data.segments.isEmpty, pts.count > 1 {
            ctx.stroke(path(0...(pts.count - 1)), with: .color(.white.opacity(0.8)), style: casing)
            ctx.stroke(path(0...(pts.count - 1)), with: .color(.gray), lineWidth: 4)
        }
        for faded in [true, false] {
            for seg in data.segments {
                let r: ClosedRange<Int>
                if faded {
                    guard seg.last > cut else { continue }
                    r = max(seg.first, min(cut, seg.last))...seg.last
                } else {
                    guard seg.first <= cut else { continue }
                    r = seg.first...min(seg.last, cut)
                }
                let color = seg.type.color.opacity(faded ? 0.3 : 1)
                if seg.type == .stationary {
                    let c = pts[seg.first]
                    let dot = Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14))
                    if !faded { ctx.fill(dot, with: .color(.white.opacity(0.8))) }
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11)), with: .color(color))
                    continue
                }
                let p = path(r)
                if !faded { ctx.stroke(p, with: .color(.white.opacity(0.8)), style: casing) }
                ctx.stroke(p, with: .color(color),
                           style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round,
                                              dash: seg.type.isDashed ? [7, 6] : []))
            }
        }
        if let i = marker ?? (showsLastPoint ? pts.count - 1 : nil), pts.indices.contains(i) {
            let c = pts[i]
            let color = marker == nil ? Color.blue : (data.segment(at: i)?.type.color ?? .blue)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)), with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6.5, y: c.y - 6.5, width: 13, height: 13)), with: .color(color))
        }
    }
}

struct OSMAttribution: View {
    @ObservedObject private var settings = MapSettings.shared

    var body: some View {
        if settings.tilesOn {
            Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                .padding(4)
        }
    }
}

// MARK: - Inline card

/// The day's map at a glance (fits the whole day). Tap to open the full-screen, zoomable map.
struct DayMapCard: View {
    let data: DayMapData
    var emptyText = "No points yet"
    var showsLastPoint = true
    let onOpen: () -> Void

    var body: some View {
        GeometryReader { geo in
            DayMapCanvas(data: data, camera: data.fit(size: geo.size, inset: 22), showsLastPoint: showsLastPoint)
        }
        .overlay {
            if data.points.isEmpty {
                Text(emptyText).foregroundStyle(.secondary)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !data.points.isEmpty {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .padding(8)
                    .background(.thinMaterial, in: Circle())
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottomTrailing) { OSMAttribution() }
        .contentShape(Rectangle())
        .onTapGesture { if !data.points.isEmpty { onOpen() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of the day")
        .accessibilityHint("Opens a map you can zoom")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if !data.points.isEmpty { onOpen() } }
    }
}

// MARK: - Full screen

/// Opens the full-screen map, optionally zoomed to a stretch of the day.
struct DayMapRequest: Identifiable {
    let id = UUID()
    var focus: ClosedRange<Int>?
}

/// Full-screen map: drag to pan, pinch to zoom, double-tap to zoom in, and a time scrubber.
struct DayMapScreen: View {
    let title: String
    let data: DayMapData
    var focus: ClosedRange<Int>?
    var placeName: (Segment) -> String? = { _ in nil }
    var showsLastPoint = true

    init(title: String, data: DayMapData, focus: ClosedRange<Int>? = nil,
         placeName: @escaping (Segment) -> String? = { _ in nil }, showsLastPoint: Bool = true) {
        self.title = title
        self.data = data
        self.focus = focus
        self.placeName = placeName
        self.showsLastPoint = showsLastPoint
    }

    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCamera?
    @State private var gestureStart: MapCamera?
    @State private var scrub: Double = 0
    @State private var scrubbed = false
    @State private var size: CGSize = .zero

    private var lastIndex: Int { max(data.points.count - 1, 0) }
    private var scrubIndex: Int { min(max(Int(scrub.rounded()), 0), lastIndex) }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let cam = camera ?? fitted(geo.size)
                DayMapCanvas(data: data, camera: cam,
                             cutoff: scrubbed ? scrubIndex : nil,
                             marker: scrubbed ? scrubIndex : nil,
                             showsLastPoint: showsLastPoint)
                    .contentShape(Rectangle())
                    .gesture(panZoom(geo.size, current: cam))
                    .onTapGesture(count: 2, coordinateSpace: .local) { loc in
                        zoom(by: 1, at: loc, in: geo.size, from: cam)
                    }
                    .onAppear { size = geo.size }
                    .onChange(of: geo.size) { _, new in size = new }
                    .overlay(alignment: .bottomTrailing) { OSMAttribution() }
                    .overlay(alignment: .topTrailing) { zoomButtons(geo.size, cam) }
            }
            .ignoresSafeArea(edges: .horizontal)
            .safeAreaInset(edge: .bottom, spacing: 0) { scrubber }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        camera = nil
                        scrubbed = false
                        scrub = Double(lastIndex)
                    } label: {
                        Image(systemName: "scope")
                    }
                    .accessibilityLabel("Show the whole day")
                }
            }
            .onAppear { scrub = Double(focus?.lowerBound ?? lastIndex) }
        }
    }

    private func fitted(_ size: CGSize) -> MapCamera {
        data.fit(size: size, inset: 40, range: focus)
    }

    // MARK: Gestures

    private func panZoom(_ size: CGSize, current: MapCamera) -> some Gesture {
        SimultaneousGesture(DragGesture(minimumDistance: 1), MagnifyGesture())
            .onChanged { value in
                let base = gestureStart ?? current
                if gestureStart == nil { gestureStart = current }
                var cam = base
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let anchor = value.second?.startLocation ?? center
                let anchorWorld = base.world(at: anchor, in: size)
                if let m = value.second?.magnification, m > 0 {
                    cam.zoom = min(max(base.zoom + log2(Double(m)), MapCamera.minZoom), MapCamera.maxZoom)
                }
                let ws = cam.worldSize()
                let t = value.first?.translation ?? .zero
                cam.x = Double(anchorWorld.x) - (Double(anchor.x) - Double(center.x) + Double(t.width)) / ws
                cam.y = Double(anchorWorld.y) - (Double(anchor.y) - Double(center.y) + Double(t.height)) / ws
                camera = cam.clamped()
            }
            .onEnded { _ in gestureStart = nil }
    }

    private func zoom(by delta: Double, at point: CGPoint, in size: CGSize, from cam: MapCamera) {
        let anchorWorld = cam.world(at: point, in: size)
        var next = cam
        next.zoom = min(max(cam.zoom + delta, MapCamera.minZoom), MapCamera.maxZoom)
        let ws = next.worldSize()
        next.x = Double(anchorWorld.x) - (Double(point.x) - Double(size.width) / 2) / ws
        next.y = Double(anchorWorld.y) - (Double(point.y) - Double(size.height) / 2) / ws
        camera = next.clamped()
    }

    private func zoomButtons(_ size: CGSize, _ cam: MapCamera) -> some View {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return VStack(spacing: 0) {
            Button { zoom(by: 1, at: center, in: size, from: cam) } label: {
                Image(systemName: "plus").frame(width: 40, height: 40)
            }
            .accessibilityLabel("Zoom in")
            Divider().frame(width: 40)
            Button { zoom(by: -1, at: center, in: size, from: cam) } label: {
                Image(systemName: "minus").frame(width: 40, height: 40)
            }
            .accessibilityLabel("Zoom out")
        }
        .font(.body.weight(.semibold))
        .tint(.primary)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }

    // MARK: Scrubber

    private var scrubber: some View {
        VStack(spacing: 6) {
            if data.points.indices.contains(scrubIndex) {
                let p = data.points[scrubIndex]
                let seg = data.segment(at: scrubIndex)
                HStack(spacing: 8) {
                    if let seg {
                        Image(systemName: seg.type.symbol)
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(seg.type.color))
                        Text(seg.type == .stationary ? (placeName(seg) ?? seg.type.label)
                                                     : (placeName(seg).map { "\(seg.type.label) · \($0)" } ?? seg.type.label))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(p.t.formatted(date: .omitted, time: .shortened))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if lastIndex > 0 {
                Slider(value: $scrub, in: 0...Double(lastIndex), onEditingChanged: { editing in
                    if editing { scrubbed = true }
                })
                .onChange(of: scrub) { _, _ in
                    guard scrubbed else { return }
                    keepMarkerVisible()
                }
                .accessibilityLabel("Time of day")
                .accessibilityValue(data.points.indices.contains(scrubIndex)
                                    ? data.points[scrubIndex].t.formatted(date: .omitted, time: .shortened) : "")
                HStack {
                    Text(data.points.first?.t.formatted(date: .omitted, time: .shortened) ?? "")
                    Spacer()
                    Text("Drag to replay the day")
                    Spacer()
                    Text(data.points.last?.t.formatted(date: .omitted, time: .shortened) ?? "")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    /// Pans (without zooming) when the scrubbed position leaves the visible area.
    private func keepMarkerVisible() {
        guard size.width > 0, data.world.indices.contains(scrubIndex) else { return }
        let cam = camera ?? fitted(size)
        let s = cam.screen(data.world[scrubIndex], in: size)
        let margin = 40.0
        if s.x < margin || s.y < margin || s.x > size.width - margin || s.y > size.height - margin {
            var next = cam
            next.x = Double(data.world[scrubIndex].x)
            next.y = Double(data.world[scrubIndex].y)
            camera = next.clamped()
        }
    }
}
