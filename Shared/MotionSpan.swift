import Foundation

/// A stretch of time the motion coprocessor classified as one activity.
/// The iPhone keeps 7 days of this history even while Pos XY isn't running, so the app backfills
/// it whenever it wakes up and the viewers use it to label gaps that have no GPS points.
/// Port twin: the motion helpers in web/static/js/segmenter.js.
struct MotionSpan: Codable, Hashable {
    var start: Date
    var end: Date
    var act: ActivityType
}

enum MotionSpans {
    /// Activities that count as movement, in tie-break order.
    static let moving: [ActivityType] = [.walking, .running, .cycling, .driving]

    /// Sorts by start and drops exact duplicates (same start and activity), keeping the first.
    static func normalized(_ spans: [MotionSpan]) -> [MotionSpan] {
        var seen = Set<String>()
        return spans.filter { $0.end > $0.start && $0.act != .unknown }
            .sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
            .filter { seen.insert("\($0.start.timeIntervalSince1970)|\($0.act.rawValue)").inserted }
    }

    /// Index of the first span whose end is after `t` (spans sorted, non-overlapping).
    private static func firstEnding(after t: Date, in spans: [MotionSpan]) -> Int {
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].end <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The activity at time `t`, if a span covers it.
    static func activity(at t: Date, in spans: [MotionSpan]) -> ActivityType? {
        let i = firstEnding(after: t, in: spans)
        guard i < spans.count, spans[i].start <= t else { return nil }
        return spans[i].act
    }

    /// The main moving activity between `a` and `b`, if movement covers at least
    /// min(3 minutes, 20 % of the interval). Ties go to the earlier type in `moving`.
    static func dominantMoving(from a: Date, to b: Date, in spans: [MotionSpan]) -> ActivityType? {
        guard b > a, !spans.isEmpty else { return nil }
        var total: TimeInterval = 0
        var byType: [ActivityType: TimeInterval] = [:]
        var i = firstEnding(after: a, in: spans)
        while i < spans.count, spans[i].start < b {
            let s = spans[i]
            if moving.contains(s.act) {
                let overlap = min(s.end, b).timeIntervalSince(max(s.start, a))
                if overlap > 0 { byType[s.act, default: 0] += overlap; total += overlap }
            }
            i += 1
        }
        guard total >= min(180, 0.2 * b.timeIntervalSince(a)) else { return nil }
        var best: ActivityType?
        var bestValue = -1.0
        for t in moving { if let v = byType[t], v > bestValue { best = t; bestValue = v } }
        return best
    }

    /// Points without their own activity tag get the activity of the span that covers them.
    static func fill(_ points: [TrackPoint], from spans: [MotionSpan]) -> [TrackPoint] {
        guard !spans.isEmpty else { return points }
        return points.map { p in
            guard p.act == nil || p.act == .unknown, let a = activity(at: p.t, in: spans) else { return p }
            var q = p
            q.act = a
            return q
        }
    }

    /// Spans that overlap [a, b).
    static func overlapping(_ spans: [MotionSpan], from a: Date, to b: Date) -> [MotionSpan] {
        var out: [MotionSpan] = []
        var i = firstEnding(after: a, in: spans)
        while i < spans.count, spans[i].start < b { out.append(spans[i]); i += 1 }
        return out
    }
}
