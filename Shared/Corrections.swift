import Foundation

/// A manual fix: "from `start` to `end` I was actually on a train". Made on the iPhone (History)
/// or in the web viewer, stored by time range so it survives re-segmentation, and exported.
/// Port twin: applyCorrections in web/static/js/segmenter.js. Spec: docs/FORMAT.md §2.2.
struct ActivityCorrection: Codable, Hashable {
    var start: Date
    var end: Date
    var act: ActivityType
}

enum Corrections {
    /// Applies corrections in order (later ones win): a segment covered by a correction for at
    /// least half its duration takes that activity. Then neighbouring segments with the same
    /// activity merge into one.
    static func apply(_ corrections: [ActivityCorrection], to segments: [Segment]) -> [Segment] {
        guard !corrections.isEmpty else { return segments }
        let relabelled = segments.map { seg -> Segment in
            var s = seg
            let duration = seg.duration
            guard duration > 0 else { return s }
            for c in corrections where c.act != .unknown {
                let overlap = min(c.end, seg.end).timeIntervalSince(max(c.start, seg.start))
                if overlap >= 0.5 * duration { s.type = c.act }
            }
            return s
        }
        var merged: [Segment] = []
        for s in relabelled {
            if var last = merged.last, last.type == s.type {
                last.last = s.last
                last.end = s.end
                last.distance += s.distance
                merged[merged.count - 1] = last
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    /// Corrections minus any that cover at least half of [start, end] ("back to automatic").
    static func removing(_ corrections: [ActivityCorrection], from start: Date, to end: Date) -> [ActivityCorrection] {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return corrections }
        return corrections.filter { c in
            min(c.end, end).timeIntervalSince(max(c.start, start)) < 0.5 * span
        }
    }

    /// Valid ones only (end after start, a known activity), sorted by start, order otherwise kept.
    static func normalized(_ corrections: [ActivityCorrection]) -> [ActivityCorrection] {
        corrections.filter { $0.end > $0.start && $0.act != .unknown }
            .enumerated()
            .sorted { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
            .map(\.element)
    }
}
