import Foundation

/// A stay (stationary segment) reduced to where and when.
struct Stay: Hashable {
    var lat: Double
    var lon: Double
    var start: Date
    var end: Date
}

/// A place you keep coming back to: Home, Work, or "Place N".
struct Place: Identifiable, Hashable {
    enum Label: String { case home, work }

    var id: Int                 // rank by total time, 0 = most time
    var lat: Double
    var lon: Double
    var visits: Int
    var seconds: TimeInterval
    var night: TimeInterval     // time between 22:00 and 06:00
    var work: TimeInterval      // time Mon–Fri 09:00–17:00
    var days: Int
    var label: Label?
    /// "Home", "Work", "Place N", or nil for places too minor to name.
    var name: String?

    /// SF Symbol for the place.
    var symbol: String {
        switch label {
        case .home: return "house.fill"
        case .work: return "briefcase.fill"
        case nil: return "mappin.circle.fill"
        }
    }
}

/// Clusters stays from all days into places and names them.
/// Port twin: web/static/js/places.js (web/tests/places.test.mjs pins both to the same output).
enum Places {
    static let radius: Double = 150                 // metres
    static let minimumStay: TimeInterval = 5 * 60
    private static let nightMinimum: TimeInterval = 4 * 3600
    private static let workMinimum: TimeInterval = 4 * 3600

    /// Stays (stationary segments of at least `minimumStay`) of one day's cleaned points.
    static func stays(points: [TrackPoint], segments: [Segment]) -> [Stay] {
        segments.compactMap { s in
            guard s.type == .stationary, s.duration >= minimumStay else { return nil }
            var lat = 0.0, lon = 0.0
            for i in s.first...s.last { lat += points[i].lat; lon += points[i].lon }
            let n = Double(s.last - s.first + 1)
            return Stay(lat: lat / n, lon: lon / n, start: s.start, end: s.end)
        }
    }

    /// Seconds of [s, e] in local night (22:00–06:00) and weekday office hours (Mon–Fri 9–17).
    static func windowSeconds(_ s: Date, _ e: Date, calendar cal: Calendar = .current) -> (night: TimeInterval, work: TimeInterval) {
        func overlap(_ a0: Date, _ a1: Date, _ b0: Date, _ b1: Date) -> TimeInterval {
            max(0, min(a1, b1).timeIntervalSince(max(a0, b0)))
        }
        var night: TimeInterval = 0, work: TimeInterval = 0
        var day = cal.startOfDay(for: s)
        while day < e {
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            func at(_ hour: Int) -> Date {
                var c = comps
                c.hour = hour
                return cal.date(from: c) ?? day
            }
            let next = cal.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            night += overlap(s, e, at(0), at(6)) + overlap(s, e, at(22), next)
            let weekday = cal.component(.weekday, from: day)     // 1 = Sunday
            if (2...6).contains(weekday) { work += overlap(s, e, at(9), at(17)) }
            day = next
        }
        return (night, work)
    }

    private final class Cluster {
        var lat: Double, lon: Double, weight: Double
        var visits = 0
        var seconds: TimeInterval = 0, night: TimeInterval = 0, work: TimeInterval = 0
        var dayKeys = Set<String>()
        init(lat: Double, lon: Double, weight: Double) { self.lat = lat; self.lon = lon; self.weight = weight }
    }

    static func detect(_ stays: [Stay], calendar cal: Calendar = .current) -> [Place] {
        var clusters: [Cluster] = []
        for s in stays.sorted(by: { $0.start < $1.start }) {
            var best: Cluster?
            var bestD = Double.infinity
            for c in clusters {
                let d = Geo.distance(lat1: c.lat, lon1: c.lon, lat2: s.lat, lon2: s.lon)
                if d <= radius && d < bestD { best = c; bestD = d }
            }
            let w = max(s.end.timeIntervalSince(s.start), 1)
            let win = windowSeconds(s.start, s.end, calendar: cal)
            let c: Cluster
            if let b = best {
                b.lat = (b.lat * b.weight + s.lat * w) / (b.weight + w)
                b.lon = (b.lon * b.weight + s.lon * w) / (b.weight + w)
                b.weight += w
                c = b
            } else {
                c = Cluster(lat: s.lat, lon: s.lon, weight: w)
                clusters.append(c)
            }
            c.visits += 1
            c.seconds += s.end.timeIntervalSince(s.start)
            c.night += win.night
            c.work += win.work
            let d = cal.dateComponents([.year, .month, .day], from: s.start)
            c.dayKeys.insert("\(d.year ?? 0)-\(d.month ?? 0)-\(d.day ?? 0)")
        }

        // Stable sort by total time, most first (ties keep first-seen order, as in JS).
        let sorted = clusters.enumerated()
            .sorted { $0.element.seconds != $1.element.seconds ? $0.element.seconds > $1.element.seconds : $0.offset < $1.offset }
            .map(\.element)
        var home: Cluster?
        for c in sorted where c.night >= nightMinimum && (home == nil || c.night > home!.night) { home = c }
        var workPlace: Cluster?
        for c in sorted where c !== home && c.work >= workMinimum && c.dayKeys.count >= 2 {
            if workPlace == nil || c.work > workPlace!.work { workPlace = c }
        }

        var rank = 0
        return sorted.enumerated().map { i, c in
            let label: Place.Label? = c === home ? .home : (c === workPlace ? .work : nil)
            let significant = c.seconds >= 30 * 60 || c.visits >= 2
            let name: String?
            switch label {
            case .home: name = "Home"
            case .work: name = "Work"
            case nil:
                if significant { rank += 1; name = "Place \(rank)" } else { name = nil }
            }
            return Place(id: i, lat: c.lat, lon: c.lon, visits: c.visits, seconds: c.seconds,
                         night: c.night, work: c.work, days: c.dayKeys.count, label: label, name: name)
        }
    }

    /// The named place within `radius` of a coordinate, if any.
    static func nearest(_ places: [Place], lat: Double, lon: Double) -> Place? {
        var best: Place?
        var bestD = Double.infinity
        for p in places where p.name != nil {
            let d = Geo.distance(lat1: p.lat, lon1: p.lon, lat2: lat, lon2: lon)
            if d <= radius && d < bestD { best = p; bestD = d }
        }
        return best
    }

    /// The named place a stay segment was at, if any.
    static func place(for s: Segment, points: [TrackPoint], in places: [Place]) -> Place? {
        guard s.type == .stationary, !places.isEmpty, s.last < points.count else { return nil }
        var lat = 0.0, lon = 0.0
        for i in s.first...s.last { lat += points[i].lat; lon += points[i].lon }
        let n = Double(s.last - s.first + 1)
        return nearest(places, lat: lat / n, lon: lon / n)
    }

    /// Detects places across many days. `days` are raw points grouped however; each group is
    /// cleaned and segmented. Can be slow for years of data: call off the main thread.
    static func detect(days: [[TrackPoint]]) -> [Place] {
        var all: [Stay] = []
        for raw in days {
            let pts = Segmenter.clean(raw)
            all += stays(points: pts, segments: Segmenter.segments(pts))
        }
        return detect(all)
    }
}
