import Foundation

/// One recorded GPS fix. Short keys keep the files small.
struct TrackPoint: Codable, Hashable {
    /// Timestamp of the fix.
    var t: Date
    var lat: Double
    var lon: Double
    /// Altitude in metres (nil if unknown).
    var alt: Double?
    /// Horizontal accuracy in metres.
    var acc: Double?
    /// Speed in m/s from the GPS chip (nil if unknown).
    var spd: Double?
    /// Course in degrees.
    var crs: Double?
    /// What the phone's motion coprocessor thought you were doing.
    var act: ActivityType?
}

enum TrackJSON {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

enum Geo {
    /// Great-circle distance in metres.
    static func distance(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        distance(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
    }

    static func distance(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = p2 - p1
        let dl = (lon2 - lon1) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
