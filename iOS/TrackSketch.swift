import SwiftUI

/// Draws a day's track on a plain canvas: no map tiles, so no network requests at all.
struct TrackSketch: View {
    let points: [TrackPoint]
    let segments: [Segment]

    var body: some View {
        Canvas { ctx, size in
            guard let proj = Projection(points: points, size: size, inset: 14) else { return }

            // Faint grid so it reads as "a map".
            var grid = Path()
            stride(from: 0, through: size.width, by: 24).forEach { x in
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: 0, through: size.height, by: 24).forEach { y in
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(grid, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)

            if segments.isEmpty, points.count > 1 {
                ctx.stroke(path(points.indices, proj), with: .color(.gray), lineWidth: 3)
            }
            for seg in segments {
                if seg.type == .stationary {
                    let c = proj.point(points[seg.first])
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)),
                             with: .color(seg.type.color.opacity(0.5)))
                    continue
                }
                let style = StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round,
                                        dash: seg.type.isDashed ? [6, 5] : [])
                ctx.stroke(path(seg.first...seg.last, proj), with: .color(seg.type.color), style: style)
            }
            if let last = points.last {
                let c = proj.point(last)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(.white))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(.blue))
            }
        }
        .overlay {
            if points.isEmpty {
                Text("No points yet today").foregroundStyle(.secondary)
            }
        }
    }

    private func path<S: Sequence>(_ indices: S, _ proj: Projection) -> Path where S.Element == Int {
        var p = Path()
        var first = true
        for i in indices {
            let pt = proj.point(points[i])
            if first { p.move(to: pt); first = false } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// Simple equirectangular fit-to-rect projection.
private struct Projection {
    let minLat: Double, minLon: Double
    let kx: Double, scale: Double
    let offset: CGPoint
    let height: Double

    init?(points: [TrackPoint], size: CGSize, inset: Double) {
        guard let f = points.first else { return nil }
        var lo = (lat: f.lat, lon: f.lon), hi = lo
        for p in points {
            lo.lat = min(lo.lat, p.lat); lo.lon = min(lo.lon, p.lon)
            hi.lat = max(hi.lat, p.lat); hi.lon = max(hi.lon, p.lon)
        }
        kx = cos((lo.lat + hi.lat) / 2 * .pi / 180)
        let w = max((hi.lon - lo.lon) * kx, 0.002)     // at least ~200 m across
        let h = max(hi.lat - lo.lat, 0.002)
        let availW = max(Double(size.width) - 2 * inset, 1)
        let availH = max(Double(size.height) - 2 * inset, 1)
        scale = min(availW / w, availH / h)
        minLat = lo.lat; minLon = lo.lon
        height = Double(size.height)
        offset = CGPoint(x: (Double(size.width) - (hi.lon - lo.lon) * kx * scale) / 2,
                         y: (Double(size.height) - (hi.lat - lo.lat) * scale) / 2)
    }

    func point(_ p: TrackPoint) -> CGPoint {
        let x = (p.lon - minLon) * kx * scale + Double(offset.x)
        let y = (p.lat - minLat) * scale + Double(offset.y)
        return CGPoint(x: x, y: height - y)
    }
}
