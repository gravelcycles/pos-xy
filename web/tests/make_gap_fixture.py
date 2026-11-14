#!/usr/bin/env python3
"""Generates fixtures/sample-day-gap-motion.json from sample-day.json.

Simulates iOS suspending the app during the morning drive: the points in the middle of the drive
are removed (a ~25-minute hole), but the phone's motion history for the whole day is kept as
`motion` spans, built from the original points' activity tags. Without the spans the hole is an
"unknown" gap; with them it should come out as a drive.
"""
import json, pathlib

here = pathlib.Path(__file__).parent / "fixtures"
day = json.loads((here / "sample-day.json").read_text())
pts = day["points"]

# Motion spans from runs of the original activity tags (end = start of the next run).
runs = []
for p in pts:
    act = p.get("act")
    if not act:
        continue
    if runs and runs[-1]["act"] == act:
        runs[-1]["last"] = p["t"]
    else:
        runs.append({"act": act, "start": p["t"], "last": p["t"]})
spans = []
for i, r in enumerate(runs):
    end = runs[i + 1]["start"] if i + 1 < len(runs) else r["last"]
    if end > r["start"]:
        spans.append({"start": r["start"], "end": end, "act": r["act"]})

# Cut the middle of the first drive: keep its first and last 3 minutes.
drive = [i for i, p in enumerate(pts) if p.get("act") == "driving"]
first, last = pts[drive[0]]["t"], pts[drive[-1]]["t"]
cut_from, cut_to = first + 180, first + 180 + 25 * 60
kept = [p for p in pts if not (cut_from < p["t"] < cut_to)]

out = {"format": "pos-xy", "version": 1, "exportedAt": day["exportedAt"], "points": kept, "motion": spans}
(here / "sample-day-gap-motion.json").write_text(json.dumps(out, separators=(",", ":")))
print(f"{len(pts)} -> {len(kept)} points, {len(spans)} motion spans, cut {cut_from:.0f}..{cut_to:.0f}")
