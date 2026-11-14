import Foundation

/// A stretch of the day spent doing one thing (walking, driving, staying put…).
/// Segments share their boundary point: `segments[k].last == segments[k+1].first`.
struct Segment: Identifiable, Hashable {
    var id: Int { first }
    var type: ActivityType
    /// Index of the first point (into the day's cleaned point array).
    var first: Int
    /// Index of the last point (inclusive).
    var last: Int
    var start: Date
    var end: Date
    /// Metres travelled.
    var distance: Double

    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct ActivityTotal: Identifiable, Hashable {
    var id: ActivityType { type }
    var type: ActivityType
    var distance: Double
    var duration: TimeInterval
}

/// Turns raw GPS fixes into labelled segments.
///
/// 1. Each point gets a label from the motion coprocessor (if recorded) checked against its speed.
/// 2. Labels are smoothed with a ±60 s majority vote.
/// 3. Each *edge* between consecutive points gets a label; long silences become stays,
///    flights (fast jumps) or unknown gaps.
/// 4. Runs that are too short to be real (a 30 s "drive" in the middle of a walk) are absorbed
///    into their neighbours.
/// 5. Runs recorded without motion data are re-classified from their speed profile.
enum Segmenter {
    /// Silence longer than this always counts as a gap (for continuous recording).
    static let minimumGap: TimeInterval = 5 * 60

    /// Silence longer than this breaks the line. Adapts to the recording frequency: with a point
    /// every 15 minutes, 15 minutes of silence is normal, not a gap.
    /// Rule: max(5 min, 2.5 × median spacing), capped at 6 h.
    static func gapThreshold(_ p: [TrackPoint]) -> TimeInterval {
        guard p.count >= 3 else { return minimumGap }
        var dts = (1..<p.count).map { p[$0].t.timeIntervalSince(p[$0 - 1].t) }
        dts.sort()
        let median = dts[dts.count / 2]
        return min(max(minimumGap, median * 2.5), 6 * 3600)
    }

    // MARK: - Cleaning

    /// Sorts, de-duplicates and removes inaccurate fixes and single-point GPS spikes.
    static func clean(_ raw: [TrackPoint]) -> [TrackPoint] {
        let sorted = raw.sorted { $0.t < $1.t }
        var out: [TrackPoint] = []
        out.reserveCapacity(sorted.count)
        for p in sorted {
            if let acc = p.acc, acc > 250 { continue }
            guard abs(p.lat) <= 90, abs(p.lon) <= 180, !(p.lat == 0 && p.lon == 0) else { continue }
            if let last = out.last, p.t.timeIntervalSince(last.t) < 0.5 { continue }
            out.append(p)
        }
        guard out.count >= 3 else { return out }

        // A -> B -> C where B shoots off and C comes straight back: B is a glitch.
        var keep = [Bool](repeating: true, count: out.count)
        for i in 1..<(out.count - 1) {
            let a = out[i - 1], b = out[i], c = out[i + 1]
            let ab = Geo.distance(a, b), bc = Geo.distance(b, c), ac = Geo.distance(a, c)
            let dtab = max(b.t.timeIntervalSince(a.t), 1)
            let dtbc = max(c.t.timeIntervalSince(b.t), 1)
            if ab / dtab > 80, bc / dtbc > 80, ac < 0.3 * min(ab, bc) {
                keep[i] = false
            }
        }
        return zip(out, keep).compactMap { $1 ? $0 : nil }
    }

    // MARK: - Speed

    /// Best speed estimate (m/s) for each point: GPS doppler speed if present, otherwise
    /// distance/time across the neighbouring points.
    static func speeds(_ p: [TrackPoint], gap: TimeInterval? = nil) -> [Double] {
        let gapThreshold = gap ?? self.gapThreshold(p)
        let n = p.count
        var s = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if let v = p[i].spd, v >= 0 { s[i] = v; continue }
            var lo = i, hi = i
            if i > 0, p[i].t.timeIntervalSince(p[i - 1].t) <= gapThreshold { lo = i - 1 }
            if i < n - 1, p[i + 1].t.timeIntervalSince(p[i].t) <= gapThreshold { hi = i + 1 }
            let dt = p[hi].t.timeIntervalSince(p[lo].t)
            s[i] = dt > 0 ? Geo.distance(p[lo], p[hi]) / dt : 0
        }
        return s
    }

    static func speedClass(_ v: Double, altitude: Double?) -> ActivityType {
        if v >= 60 || (v >= 35 && (altitude ?? 0) > 2000) { return .flying }
        if v < 0.6 { return .stationary }
        if v < 2.3 { return .walking }
        if v < 3.8 { return .running }
        if v < 8.5 { return .cycling }
        return .driving
    }

    /// Classifies a whole run of points from its speed profile (used when there was no motion data).
    static func classifyBySpeed(_ speeds: [Double]) -> ActivityType {
        guard !speeds.isEmpty else { return .unknown }
        let s = speeds.sorted()
        let median = s[s.count / 2]
        let p90 = s[Int(Double(s.count - 1) * 0.9)]
        if p90 >= 60 { return .flying }
        if median < 0.7 && p90 < 2 { return .stationary }
        if p90 < 2.6 { return .walking }
        if p90 < 4.2 && median >= 2.0 { return .running }
        if p90 < 9.5 { return .cycling }
        return .driving
    }

    /// Combines the motion-coprocessor label with a speed sanity check.
    static func pointLabel(_ p: TrackPoint, speed v: Double) -> ActivityType {
        let s = speedClass(v, altitude: p.alt)
        if s == .flying { return .flying }          // planes often look "stationary" or "automotive"
        guard let m = p.act, m != .unknown else { return s }
        switch m {
        case .stationary: return v > 3 ? s : .stationary
        case .walking, .running: return v > 6 ? s : m
        case .cycling: return v > 17 ? .driving : .cycling
        case .driving: return .driving               // includes stopped at a light
        case .flying: return .flying
        case .unknown: return s
        }
    }

    /// Majority vote over a ±`window` second neighbourhood.
    static func smooth(_ labels: [ActivityType], _ p: [TrackPoint], window: TimeInterval = 60) -> [ActivityType] {
        var out = labels
        var counts: [ActivityType: Int] = [:]
        var lo = 0, hi = 0
        for i in 0..<p.count {
            while hi < p.count && p[hi].t.timeIntervalSince(p[i].t) <= window {
                counts[labels[hi], default: 0] += 1
                hi += 1
            }
            while p[i].t.timeIntervalSince(p[lo].t) > window {
                counts[labels[lo], default: 0] -= 1
                lo += 1
            }
            let mine = counts[labels[i]] ?? 0
            // Ties go to the first type in `allCases` order so results are deterministic
            // (and match web/static/js/segmenter.js).
            var bestKey = labels[i], bestValue = -1
            for t in ActivityType.allCases {
                if let c = counts[t], c > bestValue { bestKey = t; bestValue = c }
            }
            if bestValue > mine { out[i] = bestKey }
        }
        return out
    }

    // MARK: - Segmentation

    private struct Run { var type: ActivityType; var lo: Int; var hi: Int }   // edge indices, inclusive

    private static func runs(_ edges: [ActivityType]) -> [Run] {
        var result: [Run] = []
        for (i, t) in edges.enumerated() {
            if let last = result.last, last.type == t {
                result[result.count - 1].hi = i
            } else {
                result.append(Run(type: t, lo: i, hi: i))
            }
        }
        return result
    }

    /// `points` must already be cleaned (sorted, de-duplicated).
    /// `motion` (optional, sorted) is the phone's motion-coprocessor history: it labels points that
    /// have no activity tag and gaps that have no points at all (e.g. while iOS had the app suspended).
    static func segments(_ points: [TrackPoint], motion: [MotionSpan] = []) -> [Segment] {
        let p = MotionSpans.fill(points, from: motion)
        let n = p.count
        guard n >= 2 else { return [] }
        let gapThreshold = self.gapThreshold(p)
        let v = speeds(p, gap: gapThreshold)
        let labels = smooth((0..<n).map { pointLabel(p[$0], speed: v[$0]) }, p)

        // Label each edge (i -> i+1).
        var edge = [ActivityType](repeating: .unknown, count: n - 1)
        var isGap = [Bool](repeating: false, count: n - 1)
        var edgeDist = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dt = p[i + 1].t.timeIntervalSince(p[i].t)
            let d = Geo.distance(p[i], p[i + 1])
            edgeDist[i] = d
            if dt > gapThreshold {
                isGap[i] = true
                if d < 300 { edge[i] = .stationary }          // phone sat still / GPS slept
                else if d / dt > 50 { edge[i] = .flying }      // e.g. no GPS through the plane window
                else if let t = MotionSpans.dominantMoving(from: p[i].t, to: p[i + 1].t, in: motion) {
                    edge[i] = t                                // the motion chip saw what happened
                } else { edge[i] = .unknown }
            } else {
                edge[i] = labels[i + 1]
            }
        }

        func duration(_ r: Run) -> TimeInterval { p[r.hi + 1].t.timeIntervalSince(p[r.lo].t) }
        func minDuration(_ t: ActivityType) -> TimeInterval {
            switch t {
            case .stationary: return 180
            case .flying: return 0
            default: return 90
            }
        }

        // Absorb runs that are too short to be real into their longer neighbour.
        var rs = runs(edge)
        while rs.count > 1 {
            var victim: Int?
            var shortest = Double.infinity
            for (k, r) in rs.enumerated() {
                let d = duration(r)
                if d < minDuration(r.type) && d < shortest { victim = k; shortest = d }
            }
            guard let k = victim else { break }
            let left: Run? = k > 0 ? rs[k - 1] : nil
            let right: Run? = k < rs.count - 1 ? rs[k + 1] : nil
            let target: ActivityType
            if let l = left, let r = right {
                target = duration(l) >= duration(r) ? l.type : r.type
            } else if let l = left {
                target = l.type
            } else if let r = right {
                target = r.type
            } else {
                break
            }
            for e in rs[k].lo...rs[k].hi { edge[e] = target }
            rs = runs(edge)
        }

        // Runs recorded mostly without motion data: classify from the speed profile instead.
        var changed = false
        for r in rs where r.type != .flying && r.type != .unknown {
            let idx = Array(r.lo...(r.hi + 1))
            let withMotion = idx.filter { (p[$0].act ?? .unknown) != .unknown }.count
            guard Double(withMotion) < 0.5 * Double(idx.count) else { continue }
            let movingIdx = (r.lo...r.hi).filter { !isGap[$0] }
            guard !movingIdx.isEmpty else { continue }
            let t = classifyBySpeed(movingIdx.map { v[$0 + 1] })
            if t != r.type {
                for e in movingIdx { edge[e] = t }
                changed = true
            }
        }
        if changed { rs = runs(edge) }

        return rs.map { r in
            let dist = (r.lo...r.hi).reduce(0.0) { $0 + edgeDist[$1] }
            return Segment(type: r.type, first: r.lo, last: r.hi + 1,
                           start: p[r.lo].t, end: p[r.hi + 1].t, distance: dist)
        }
    }

    /// Per-activity totals for a list of segments, in `ActivityType.allCases` order.
    static func totals(_ segments: [Segment]) -> [ActivityTotal] {
        var dict: [ActivityType: ActivityTotal] = [:]
        for s in segments {
            var cur = dict[s.type] ?? ActivityTotal(type: s.type, distance: 0, duration: 0)
            cur.distance += s.distance
            cur.duration += s.duration
            dict[s.type] = cur
        }
        return ActivityType.allCases.compactMap { dict[$0] }
    }
}
