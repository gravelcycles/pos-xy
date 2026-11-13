#!/bin/bash
# CI smoke test: install the iPhone app in a simulator, simulate a short drive across
# San Francisco, then save a screenshot and the recorded day file. Run after building for
# the simulator into build/ (see .github/workflows/ci.yml).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Build/Products/Debug-iphonesimulator/PosXY.app"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")
OUT="${1:-build/sim}"
mkdir -p "$OUT"

# Newest available iPhone simulator.
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devs = json.load(sys.stdin)["devices"]
best = None
for runtime, items in devs.items():
    if "iOS" not in runtime:
        continue
    for d in items:
        if d["name"].startswith("iPhone") and d["isAvailable"]:
            key = (runtime, d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"])
print(best[1] if best else "")')
[ -n "$UDID" ] || { echo "No iPhone simulator available"; xcrun simctl list devices; exit 1; }
echo "Simulator: $UDID"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant location-always "$BUNDLE_ID"
xcrun simctl privacy "$UDID" grant motion "$BUNDLE_ID" || true

# Start with recording on (the -key value pair lands in UserDefaults' argument domain).
xcrun simctl launch "$UDID" "$BUNDLE_ID" -recorder.isRecording YES
sleep 5

# Drive from Civic Center to the Ferry Building at ~50 km/h, then walk a little.
xcrun simctl location "$UDID" start --speed=14 --interval=1 \
  37.7793,-122.4193 37.7840,-122.4075 37.7880,-122.4010 37.7925,-122.3960 37.7955,-122.3937
sleep 75
xcrun simctl location "$UDID" start --speed=1.4 --interval=2 \
  37.7955,-122.3937 37.7968,-122.3950 37.7980,-122.3975
sleep 45
xcrun simctl location "$UDID" clear || true

# Relaunch so the "Today" sketch reloads with everything recorded.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"
sleep 6
xcrun simctl io "$UDID" screenshot "$OUT/iphone-today.png"

DATA=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
cp "$DATA"/Library/Application\ Support/Tracks/*.jsonl "$OUT/" 2>/dev/null || true
COUNT=$(cat "$OUT"/*.jsonl 2>/dev/null | wc -l | tr -d ' ')
echo "Recorded points: $COUNT"
[ "$COUNT" -gt 10 ] || { echo "::error::The app recorded only $COUNT points"; exit 1; }
