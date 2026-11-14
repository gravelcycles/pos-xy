#!/usr/bin/env python3
"""Generates fixtures/sample-day-corrected.json from sample-day.json, with manual corrections:

  1. the morning drive marked as "bus", then again as "train" (later correction wins → train);
  2. the first 5 minutes of the 20-minute run marked "cycling" (< half the segment → no change).
"""
import json, pathlib

here = pathlib.Path(__file__).parent / "fixtures"
day = json.loads((here / "sample-day.json").read_text())
pts = day["points"]

def block(act):
    """Time range of the first contiguous run of points tagged `act`."""
    start = end = None
    for p in pts:
        if p.get("act") == act:
            start = p["t"] if start is None else start
            end = p["t"]
        elif start is not None:
            break
    return start, end

d0, d1 = block("driving")
r0, _ = block("running")
corrections = [
    {"start": d0, "end": d1, "act": "bus"},
    {"start": d0, "end": d1, "act": "train"},
    {"start": r0, "end": r0 + 300, "act": "cycling"},
]
out = dict(day, corrections=corrections)
(here / "sample-day-corrected.json").write_text(json.dumps(out, separators=(",", ":")))
print(f"{len(corrections)} corrections")
