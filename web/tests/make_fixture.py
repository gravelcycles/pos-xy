#!/usr/bin/env python3
"""Generates fixtures/sample-day.json: a synthetic but realistic day (seeded, reproducible)."""
import json, math, random, pathlib

random.seed(42)
t = 1762934400.0 + 7 * 3600          # 2025-11-12 07:00 in San Francisco (PST)
lat, lon = 37.7749, -122.4194
pts = []

def leg(speed, act, minutes, dt, heading, noise=3.0, reported=True, alt=15.0):
    global t, lat, lon
    for _ in range(int(minutes * 60 / dt)):
        t += dt + random.uniform(-0.5, 0.5)
        step = speed * dt
        lat += step * math.cos(heading) / 111_111 + random.gauss(0, noise) / 111_111
        lon += step * math.sin(heading) / (111_111 * math.cos(math.radians(lat))) + random.gauss(0, noise) / 111_111
        p = {"t": round(t, 3), "lat": round(lat, 6), "lon": round(lon, 6), "acc": round(random.uniform(4, 15), 1),
             "alt": round(alt + random.uniform(-2, 2), 1)}
        if reported:
            p["spd"] = round(max(0.0, speed + random.gauss(0, 0.4)), 2)
            p["crs"] = round(math.degrees(heading) % 360) % 360
        if act:
            p["act"] = act
        pts.append(p)
        heading += random.gauss(0, 0.05)

leg(0, "stationary", 20, 30, 0, noise=4)           # home
leg(1.4, "walking", 12, 8, 0.6)                    # walk to car
leg(0, "walking", 1, 8, 0.6, noise=2)              # wait at crossing
leg(12, "driving", 18, 5, 1.2)                     # drive
leg(0, "driving", 1.5, 5, 1.2, noise=1)            # red light
leg(14, "driving", 10, 5, 0.9)
leg(0, "stationary", 240, 60, 0, noise=5)          # work
leg(5.5, "cycling", 25, 6, -2.2)                   # bike ride
leg(2.8, "running", 20, 5, 2.5)                    # run
leg(0, "stationary", 30, 60, 0, noise=4)
t += 2.5 * 3600                                    # flight with no GPS
lat, lon = 34.0522, -118.2437
leg(0, None, 20, 60, 0, noise=5, reported=False)   # arrive, no motion data
leg(13, None, 15, 10, 0.3, reported=False)         # taxi ride, no motion data

out = {"format": "pos-xy", "version": 1, "exportedAt": t + 60, "points": pts}
path = pathlib.Path(__file__).with_name("fixtures") / "sample-day.json"
path.write_text(json.dumps(out, separators=(",", ":")))
print(f"{len(pts)} points -> {path}")
