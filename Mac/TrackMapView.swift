import SwiftUI
import MapKit
import AppKit

// MARK: - OpenStreetMap tiles

/// Replaces Apple's map with OpenStreetMap's standard tiles.
/// Tiles are cached on disk so revisiting an area doesn't hit the server again
/// (and to follow the OSM tile usage policy).
final class OSMTileOverlay: MKTileOverlay {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.httpAdditionalHeaders = ["User-Agent": "PosXY-Viewer/1.0 (personal location history viewer)"]
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    static func make() -> OSMTileOverlay {
        let overlay = OSMTileOverlay(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        overlay.canReplaceMapContent = true
        overlay.minimumZ = 1
        overlay.maximumZ = 19
        return overlay
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let url = self.url(forTilePath: path)
        Self.session.dataTask(with: url) { data, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result(nil, URLError(.badServerResponse))
            } else {
                result(data, error)
            }
        }.resume()
    }
}

// MARK: - Overlay types

final class TrackPolyline: MKPolyline {
    var type: ActivityType = .unknown
    var faded = false
}

final class StayCircle: MKCircle {
    var faded = false
}

final class PositionMarker: NSObject, MKAnnotation {
    @objc dynamic var coordinate = CLLocationCoordinate2D()
    var type: ActivityType = .unknown
}

extension ActivityType {
    var nsColor: NSColor { NSColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1) }
}

/// Changing `id` makes the map zoom to `first...last` (or the whole day when nil).
struct MapFocus: Equatable {
    var id = 0
    var first: Int?
    var last: Int?
}

// MARK: - Map view

struct TrackMapView: NSViewRepresentable {
    let points: [TrackPoint]
    let segments: [Segment]
    /// Changes whenever `points` is replaced (new day or newly merged file).
    let dataID: Int
    /// Points up to this index are drawn in full colour, the rest faded.
    let cutoff: Int
    let marker: CLLocationCoordinate2D?
    let markerType: ActivityType
    let follow: Bool
    let focus: MapFocus

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.addOverlay(OSMTileOverlay.make(), level: .aboveLabels)
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        map.showsZoomControls = true
        map.showsScale = true
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        if c.dataID != dataID {
            c.dataID = dataID
            c.coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            c.drawnCutoff = Int.min
        }
        if c.drawnCutoff != cutoff {
            c.drawnCutoff = cutoff
            c.redraw(map, segments: segments, cutoff: cutoff)
        }
        c.updateMarker(map, coordinate: marker, type: markerType)
        if c.focusID != focus.id {
            c.focusID = focus.id
            let coords = c.coords
            let range: ClosedRange<Int>? = {
                guard !coords.isEmpty else { return nil }
                let lo = max(0, min(focus.first ?? 0, coords.count - 1))
                let hi = max(lo, min(focus.last ?? coords.count - 1, coords.count - 1))
                return lo...hi
            }()
            if let range {
                // On first display the view has no size yet; wait a tick.
                DispatchQueue.main.async { c.fit(map, coords[range]) }
            }
        } else if follow, let m = marker {
            map.setCenter(m, animated: false)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var coords: [CLLocationCoordinate2D] = []
        var dataID = Int.min
        var drawnCutoff = Int.min
        var focusID = -1
        private var trackOverlays: [MKOverlay] = []
        private var marker: PositionMarker?

        func redraw(_ map: MKMapView, segments: [Segment], cutoff: Int) {
            map.removeOverlays(trackOverlays)
            trackOverlays.removeAll()

            func line(_ lo: Int, _ hi: Int, _ type: ActivityType, faded: Bool) {
                guard hi > lo else { return }
                let slice = Array(coords[lo...hi])
                let l = TrackPolyline(coordinates: slice, count: slice.count)
                l.type = type
                l.faded = faded
                trackOverlays.append(l)
            }

            if segments.isEmpty && coords.count >= 2 {
                line(0, coords.count - 1, .unknown, faded: false)
            }
            for seg in segments {
                if seg.type == .stationary {
                    let mid = coords[(seg.first + seg.last) / 2]
                    let circle = StayCircle(center: mid, radius: 35)
                    circle.faded = seg.first > cutoff
                    trackOverlays.append(circle)
                    continue
                }
                if seg.first < cutoff { line(seg.first, min(seg.last, cutoff), seg.type, faded: false) }
                if seg.last > cutoff { line(max(seg.first, cutoff), seg.last, seg.type, faded: true) }
            }
            map.addOverlays(trackOverlays, level: .aboveLabels)
        }

        func updateMarker(_ map: MKMapView, coordinate: CLLocationCoordinate2D?, type: ActivityType) {
            guard let coordinate else {
                if let m = marker { map.removeAnnotation(m); marker = nil }
                return
            }
            if let m = marker {
                m.coordinate = coordinate
                if m.type != type {
                    m.type = type
                    if let v = map.view(for: m) as? MKMarkerAnnotationView { style(v, type) }
                }
            } else {
                let m = PositionMarker()
                m.coordinate = coordinate
                m.type = type
                marker = m
                map.addAnnotation(m)
            }
        }

        func fit(_ map: MKMapView, _ slice: ArraySlice<CLLocationCoordinate2D>) {
            guard let first = slice.first else { return }
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            for c in slice {
                let p = MKMapPoint(c)
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            var rect = MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let minSize = MKMapPointsPerMeterAtLatitude(first.latitude) * 600   // at least ~600 m across
            if rect.size.width < minSize { rect = rect.insetBy(dx: -(minSize - rect.size.width) / 2, dy: 0) }
            if rect.size.height < minSize { rect = rect.insetBy(dx: 0, dy: -(minSize - rect.size.height) / 2) }
            map.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 70, left: 50, bottom: 50, right: 50), animated: true)
        }

        private func style(_ v: MKMarkerAnnotationView, _ type: ActivityType) {
            v.markerTintColor = type.nsColor
            v.glyphImage = NSImage(systemSymbolName: type.symbol, accessibilityDescription: type.label)
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tiles)
            }
            if let line = overlay as? TrackPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = line.type.nsColor.withAlphaComponent(line.faded ? 0.45 : 0.95)
                r.lineWidth = line.faded ? 4 : 5
                r.lineCap = .round
                r.lineJoin = .round
                if line.type.isDashed { r.lineDashPattern = [8, 8] }
                return r
            }
            if let circle = overlay as? StayCircle {
                let r = MKCircleRenderer(circle: circle)
                let color = ActivityType.stationary.nsColor
                r.fillColor = color.withAlphaComponent(circle.faded ? 0.12 : 0.3)
                r.strokeColor = color.withAlphaComponent(circle.faded ? 0.3 : 0.9)
                r.lineWidth = 2
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let m = annotation as? PositionMarker else { return nil }
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: "position") as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: m, reuseIdentifier: "position")
            v.annotation = m
            v.displayPriority = .required
            v.animatesWhenAdded = false
            style(v, m.type)
            return v
        }
    }
}
