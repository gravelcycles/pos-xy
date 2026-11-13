#!/usr/bin/env python3
"""Generates fixtures/week.json: 7 synthetic days in San Francisco (local time PST, UTC-8).

Home in the Mission, work downtown on weekdays, a café some mornings, the park on the weekend.
Seeded and reproducible. Used by the places tests (web/tests/places.test.mjs).
"""
import json, math, random, pathlib

random.seed(7)
TZ = -8 * 3600
DAY0 = 1762934400                          # 08:00 UTC = 00:00 PST
HOME = (37.7599, -122.4148)
WORK = (37.7897, -122.3972)
CAFE = (37.7644, -122.4219)
PARK = (37.7694, -122.4862)
GYM = (37.7786, -122.4110)
pts = []

def at(day, h, m=0):
    return DAY0 + day * 86400 + h * 3600 + m * 60

def stay(place, t0, t1, every=120):
    t = t0
    while t < t1:
        pts.append({"t": round(t, 1), "lat": round(place[0] + random.gauss(0, 12) / 111111, 6),
                    "lon": round(place[1] + random.gauss(0, 12) / 88000, 6), "acc": 10.0,
                    "spd": round(abs(random.gauss(0, 0.2)), 2), "act": "stationary"})
        t += every + random.uniform(-10, 10)

def move(a, b, t0, speed, act):
    d = math.hypot((b[0] - a[0]) * 111111, (b[1] - a[1]) * 88000)
    dur = d / speed
    n = max(2, int(dur / 10))
    for i in range(1, n + 1):
        f = i / n
        pts.append({"t": round(t0 + f * dur, 1), "lat": round(a[0] + (b[0] - a[0]) * f, 6),
                    "lon": round(a[1] + (b[1] - a[1]) * f, 6), "acc": 8.0,
                    "spd": round(speed + random.gauss(0, 0.3), 2), "act": act})
    return t0 + dur

# Wed 12 .. Tue 18 Nov 2025 (day 0 = Wednesday).
for day in range(7):
    weekday = (2 + day) % 7          # 0=Mon … 6=Sun
    if weekday < 5:
        stay(HOME, at(day, 0), at(day, 7, 30))
        t = at(day, 7, 30)
        if day % 2 == 0:
            t = move(HOME, CAFE, t, 1.4, "walking"); stay(CAFE, t, t + 1500); t += 1500
            t = move(CAFE, WORK, t, 11, "driving")
        else:
            t = move(HOME, WORK, t, 5, "cycling")
        stay(WORK, t, at(day, 17, 30))
        t = at(day, 17, 30)
        if weekday in (1, 3):
            t = move(WORK, GYM, t, 1.5, "walking"); stay(GYM, t, t + 3600); t += 3600
            t = move(GYM, HOME, t, 11, "driving")
        else:
            t = move(WORK, HOME, t, 11, "driving")
        stay(HOME, t, at(day, 23, 59))
    else:
        stay(HOME, at(day, 0), at(day, 10))
        t = move(HOME, PARK, at(day, 10), 4.5, "cycling")
        stay(PARK, t, t + 3 * 3600); t += 3 * 3600
        t = move(PARK, HOME, t, 4.5, "cycling")
        stay(HOME, t, at(day, 23, 59))

out = {"format": "pos-xy", "version": 1, "exportedAt": at(7, 0), "points": pts}
path = pathlib.Path(__file__).with_name("fixtures") / "week.json"
path.write_text(json.dumps(out, separators=(",", ":")))
print(f"{len(pts)} points -> {path}")
