import Foundation

/// Importers for other location formats: Google Takeout (Records.json), Google Maps Timeline
/// exports (Android/web on-device and iPhone), and GPX. Everything is parsed locally.
/// Port twin: web/static/js/importers.js (fixtures in web/tests/fixtures/import).
enum Importers {
    struct Result {
        let kind: String
        let points: [TrackPoint]
    }

    private static let googleActivity: [String: ActivityType] = [
        "STILL": .stationary, "WALKING": .walking, "ON_FOOT": .walking, "RUNNING": .running,
        "ON_BICYCLE": .cycling, "CYCLING": .cycling, "FLYING": .flying,
        "IN_VEHICLE": .driving, "IN_ROAD_VEHICLE": .driving, "IN_CAR": .driving, "IN_PASSENGER_VEHICLE": .driving,
        "IN_BUS": .driving, "IN_TAXI": .driving, "MOTORCYCLING": .driving, "IN_TRAIN": .driving, "IN_SUBWAY": .driving,
        "IN_TRAM": .driving, "IN_RAIL_VEHICLE": .driving, "IN_FERRY": .driving, "IN_BOAT": .driving,
        "IN_CABLECAR": .driving, "IN_GONDOLA_LIFT": .driving, "IN_WHEELCHAIR": .walking, "SKIING": .unknown,
        "SAILING": .driving,
    ]

    static func activity(_ type: Any?) -> ActivityType {
        guard let s = type as? String else { return .unknown }
        let key = s.uppercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "[\\s-]+", with: "_", options: .regularExpression)
            .replacingOccurrences(of: "[^A-Z_]", with: "", options: .regularExpression)
        return googleActivity[key] ?? .unknown
    }

    // MARK: Parsing helpers

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    private static func number(_ any: Any?) -> Double? {
        // Note: don't reject `Bool` here: JSON 0/1 bridge as NSNumber, which also casts to Bool.
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// "52.5163°, 13.3777°", "geo:52.5163,13.3777" or "52.5163,13.3777".
    static func latLng(_ any: Any?) -> (Double, Double)? {
        guard var s = any as? String else { return nil }
        if s.hasPrefix("geo:") { s.removeFirst(4) }
        let pattern = "(-?\\d+(?:\\.\\d+)?)\\s*°?\\s*,\\s*(-?\\d+(?:\\.\\d+)?)"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s),
              let lat = Double(s[r1]), let lon = Double(s[r2]) else { return nil }
        return (lat, lon)
    }

    private static func point(_ t: Date?, _ ll: (Double, Double)?, act: ActivityType? = nil) -> TrackPoint? {
        guard let t, let ll else { return nil }
        return TrackPoint(t: t, lat: ll.0, lon: ll.1, act: act)
    }

    // MARK: Google

    static func googleRecords(_ obj: [String: Any]) -> [TrackPoint] {
        guard let locations = obj["locations"] as? [[String: Any]] else { return [] }
        var out: [TrackPoint] = []
        for l in locations {
            let t: Date? = date(l["timestamp"]) ?? number(l["timestampMs"]).map { Date(timeIntervalSince1970: $0 / 1000) }
            guard let t, let latE7 = number(l["latitudeE7"]), let lonE7 = number(l["longitudeE7"]) else { continue }
            var lat = latE7 / 1e7, lon = lonE7 / 1e7
            if lat > 90 { lat -= 4_294_967_296 / 1e7 }      // old exports stored negatives as unsigned
            if lon > 180 { lon -= 4_294_967_296 / 1e7 }
            var p = TrackPoint(t: t, lat: lat, lon: lon)
            p.acc = number(l["accuracy"])
            p.alt = number(l["altitude"])
            p.spd = number(l["velocity"])
            if let h = number(l["heading"]) { p.crs = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
            if let records = l["activity"] as? [[String: Any]],
               let candidates = records.first?["activity"] as? [[String: Any]] {
                var best: [String: Any]?
                for c in candidates where best == nil || (number(c["confidence"]) ?? 0) > (number(best?["confidence"]) ?? 0) {
                    best = c
                }
                if let best, (number(best["confidence"]) ?? 0) >= 50 { p.act = activity(best["type"]) }
            }
            out.append(p)
        }
        return out
    }

    static func googleTimeline(_ obj: [String: Any]) -> [TrackPoint] {
        var out: [TrackPoint] = []
        for s in obj["rawSignals"] as? [[String: Any]] ?? [] {
            guard let pos = s["position"] as? [String: Any],
                  var p = point(date(pos["timestamp"]), latLng(pos["LatLng"] ?? pos["latLng"])) else { continue }
            p.acc = number(pos["accuracyMeters"])
            p.alt = number(pos["altitudeMeters"])
            if let v = number(pos["speedMetersPerSecond"]), v >= 0 { p.spd = v }
            out.append(p)
        }
        for seg in obj["semanticSegments"] as? [[String: Any]] ?? [] { out += semanticSegment(seg) }
        return out
    }

    static func googleIOS(_ arr: [[String: Any]]) -> [TrackPoint] {
        arr.flatMap(semanticSegment)
    }

    private static func semanticSegment(_ seg: [String: Any]) -> [TrackPoint] {
        var out: [TrackPoint] = []
        let start = date(seg["startTime"]), end = date(seg["endTime"])
        for tp in seg["timelinePath"] as? [[String: Any]] ?? [] {
            var t = date(tp["time"])
            if t == nil, let start, let offset = number(tp["durationMinutesOffsetFromStartTime"]) {
                t = start.addingTimeInterval(offset * 60)
            }
            if let p = point(t, latLng(tp["point"])) { out.append(p) }
        }
        if let visit = seg["visit"] as? [String: Any] {
            let pl = (visit["topCandidate"] as? [String: Any])?["placeLocation"]
            let ll = latLng(pl as? String ?? (pl as? [String: Any])?["latLng"])
            for t in [start, end] { if let p = point(t, ll, act: .stationary) { out.append(p) } }
        }
        if let act = seg["activity"] as? [String: Any] {
            let type = activity((act["topCandidate"] as? [String: Any])?["type"])
            func ll(_ v: Any?) -> (Double, Double)? { latLng(v as? String ?? (v as? [String: Any])?["latLng"]) }
            if let a = point(start, ll(act["start"]), act: type) { out.append(a) }
            if let b = point(end, ll(act["end"]), act: type) { out.append(b) }
        }
        return out
    }

    // MARK: GPX

    static func gpx(_ text: String) -> [TrackPoint] {
        let pointPattern = "<(?:\\w+:)?(trkpt|rtept|wpt)\\b([^>]*?)(?:/>|>([\\s\\S]*?)</(?:\\w+:)?\\1>)"
        guard let re = try? NSRegularExpression(pattern: pointPattern) else { return [] }
        let ns = text as NSString
        func attr(_ tag: String, _ name: String) -> Double? {
            guard let r = try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']"),
                  let m = r.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let range = Range(m.range(at: 1), in: tag) else { return nil }
            return Double(tag[range])
        }
        func child(_ body: String, _ name: String) -> String? {
            guard let r = try? NSRegularExpression(pattern: "<(?:\\w+:)?\(name)\\b[^>]*>([\\s\\S]*?)</(?:\\w+:)?\(name)>"),
                  let m = r.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
                  let range = Range(m.range(at: 1), in: body) else { return nil }
            return body[range].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out: [TrackPoint] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 2))
            let body = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3))
            guard let lat = attr(tag, "lat"), let lon = attr(tag, "lon"), let t = date(child(body, "time")) else { continue }
            var p = TrackPoint(t: t, lat: lat, lon: lon)
            p.alt = child(body, "ele").flatMap(Double.init)
            p.spd = child(body, "speed").flatMap(Double.init)
            out.append(p)
        }
        return out
    }

    // MARK: Detection

    /// Recognises a foreign format, or returns nil (then it's Pos XY or unreadable).
    static func importForeign(_ data: Data) -> Result? {
        let head = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.lowercased().hasPrefix("<?xml") || head.lowercased().hasPrefix("<gpx") {
            return Result(kind: "GPX", points: gpx(String(decoding: data, as: UTF8.self)))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let obj = json as? [String: Any] {
            if obj["locations"] is [Any] { return Result(kind: "Google Takeout (Records.json)", points: googleRecords(obj)) }
            if obj["semanticSegments"] is [Any] || obj["rawSignals"] is [Any] {
                return Result(kind: "Google Maps Timeline", points: googleTimeline(obj))
            }
        }
        if let arr = json as? [[String: Any]], arr.contains(where: {
            ($0["visit"] != nil || $0["activity"] != nil || $0["timelinePath"] != nil) && $0["startTime"] != nil
        }) {
            return Result(kind: "Google Maps Timeline (iPhone)", points: googleIOS(arr))
        }
        return nil
    }
}
