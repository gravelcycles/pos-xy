# Handoff: state of Pos XY and how to continue on your Mac

This was written by the cloud Claude session that built the project, for a **local Claude Code session on the owner's Mac**. That session's first job is to get the app onto the owner's iPhone.

## 1. Kick-off prompt (paste into Claude Code on the Mac)

> Read CLAUDE.md and docs/HANDOFF.md. Then deploy the Pos XY iPhone app to my iPhone, which is connected to this Mac, following section 3 of HANDOFF.md. Run `scripts/deploy-iphone.sh`. Tell me exactly when I need to do something by hand (Xcode account, Developer Mode, trusting the certificate, location permission). After it launches, walk me through the real-device checklist in section 5 and fix anything that breaks, as PRs merged into main.

## 2. Where things stand (as of 2026-11-13)

**Merged to `main`** (PR #1):
- **iPhone app:**
  - Background GPS recording that works in airplane mode, with motion-based activity tags.
  - A "Record a point" frequency setting (continuous, 1/5/15/60 min, or custom), and pause (1 h, 4 h, until morning).
  - Siri & Shortcuts actions: Start, Stop, Pause.
  - Today sketch with the day's places, History, optional Face ID lock.
  - Export to a passphrase-locked `.pxy` or plain JSON, sent via AirDrop.
- **Mac viewer:** an OSM map, day list, scrubbable timeline with playback, and a trip list with place names. It opens `.pxy`, JSON, GPX and Google Timeline/Takeout files.
- **Web viewer:**
  - `python3 web/serve.py`: day view, all-time overview with a calendar heatmap, "Where was I?" search, renamable places, GPX export, `#day` deep links.
  - Handles 1M+ points.
- **Shared logic (Swift + JS):**
  - Segmenter: walk/run/bike/drive/flight/stay, adapting to sparse sampling.
  - Places: Home and Work inferred from night-time and weekday 9–5 stays.
  - Importers: Google Takeout `Records.json`, Google Maps Timeline exports (Android/web and iPhone), GPX.
- **Spec and tests:**
  - `docs/FORMAT.md`, a JSON Schema, and crypto test vectors from an independent Python implementation.
  - 30 JS tests, plus Swift-vs-JS parity checks: 13 comparisons, all identical.
- **CI** (`.github/workflows/ci.yml`, every push and PR):
  - Builds the Mac app and the iPhone app (device and simulator).
  - Runs the iPhone app in a simulator through a simulated drive, a walk, and timed mode (checking 2–8 points in 75 s at a 20 s interval), and verifies the recorded file with the JS reader.
  - Uploads the screenshots and the apps (`PosXYViewer-mac.zip`, `PosXY-unsigned.ipa`).
  - A `v*` tag creates a GitHub Release.

**Open:** PR #2 adds a CI step that launches the Mac viewer with a week of data and screenshots it. Merge it once CI is green and the screenshot looks right.

**Not done / needs the owner:**
- **TestFlight:** `.github/workflows/testflight.yml` exists but has never run. It needs the paid Apple Developer Program plus 4 repo secrets; setup is in `docs/DISTRIBUTION.md`. The first run may need a small signing tweak.
- **Real devices:** installed on the owner's iPhone 12 Pro (iOS 18.7.3) on 2026-11-13 with Xcode 26.6 and a free Apple ID (team `D5STMWZ849`, Personal Team). The app and widget extension both sign, but nobody has run the section 5 checklist yet. The Mac viewer still hasn't run on a real Mac.

## 3. Deploying to the owner's iPhone

Prerequisites, done by the owner:
1. **Xcode 16 or newer**, opened once so it installs its components. Check with `xcodebuild -version`, and make sure `xcode-select -p` points into `Xcode.app`.
2. **An Apple ID in Xcode:** Settings → Accounts → +. A free account works, but the app then expires after 7 days; re-run the script to refresh it, and data is kept. A paid account lasts a year.
3. **iPhone:** connect it by cable the first time, unlock it, tap **Trust**. Turn on Settings → Privacy & Security → **Developer Mode** (it restarts).

Then:
```sh
scripts/deploy-iphone.sh
```
The script:
1. finds the team ID (from the account teams Xcode and xcodebuild cache in their prefs, else from the "Apple Development" certificate) and the single paired iPhone (via `xcrun devicectl`). If `xcode-select` points at the Command Line Tools, it uses the newest `/Applications/Xcode*.app` instead;
2. builds Release with `-allowProvisioningUpdates`, so Xcode creates the signing profile;
3. installs and launches the app.

Overrides: `TEAM=…`, `DEVICE=<udid>`, `BUNDLE_ID=…`, `CONFIG=Debug`.

Likely snags and fixes:

| Symptom | Fix |
| --- | --- |
| "No signing team found" | Xcode hasn't cached the account's teams yet. Run any `xcodebuild … -allowProvisioningUpdates build` once (it fails, but writes the team to `com.apple.dt.xcodebuild`), or pass `TEAM=…`. |
| Profile "doesn't match the entitlements file's value for … application-groups" | A free Apple ID can't register App Group IDs from xcodebuild. That's why the widget status uses a shared keychain group (`keychain-access-groups`) instead; don't reintroduce an App Group. |
| "Bundle identifier is not available" (free accounts must be globally unique) | `BUNDLE_ID=com.<something-unique>.posxy scripts/deploy-iphone.sh` |
| Installs but won't launch: "Untrusted Developer" | iPhone → Settings → General → VPN & Device Management → trust the Apple ID. Then open the app. |
| Device not found | Unlock the phone, re-plug, check Developer Mode. `xcrun devicectl list devices` should show it as paired. |
| Free account: "maximum number of apps" | Free accounts can have only 3 sideloaded apps at once. Delete one. |

GUI fallback: open `PosXY.xcodeproj`, choose your team on the PosXY target, select the iPhone as the destination, then ⌘R.

**In the app, the first time:**
1. Turn on **Record my location** and choose *Allow While Using App*.
2. Later, iOS asks to upgrade the permission; choose **Change to Always Allow**. Or set it in Settings → Pos XY → Location → Always, with Precise on.
3. Allow **Motion & Fitness**.

**Mac viewer:** `scripts/install-mac-viewer.sh`, or `python3 web/serve.py` for the browser viewer.

## 4. Architecture in one screen

- **Recording** (`iOS/LocationRecorder.swift`):
  - CLLocationManager with background updates, `pausesLocationUpdatesAutomatically = false`, and significant-change monitoring so iOS relaunches the app.
  - Continuous mode: best accuracy and a 15 m distance filter. Smart mode drops to 100 m accuracy while CoreMotion says you're stationary, unless there was a fast fix in the last 10 minutes, which protects flights.
  - Timed mode and pause: a coarse 3 km "keep-alive" session with the GPS off, plus a 2 s timer. For each point it turns the GPS on until a fix of ≤20 m (≤50 m after 10 s), or a timeout of 20–90 s.
  - Fixes worse than 200 m are dropped. Each point gets the current CoreMotion activity, if at least medium confidence.
- **Storage** (`iOS/PointStore.swift`): `Application Support/Tracks/YYYY-MM-DD.jsonl`, one point per line, Data Protection `completeUntilFirstUserAuthentication`, excluded from backups.
- **Export** (`Shared/ExportCodec.swift`): JSON → raw DEFLATE → AES-256-GCM. The key comes from PBKDF2-SHA256 with 600k rounds; the 28-byte header is the associated data. Spec: `docs/FORMAT.md`.
- **Segmenter** (`Shared/Segmenter.swift`, `web/static/js/segmenter.js`), applied per point, then per edge:
  1. Label each point from the motion tag, sanity-checked against speed.
  2. Smooth with a ±60 s majority vote.
  3. Classify each gap between points. The gap threshold is max(5 min, 2.5 × median spacing).
  4. Absorb runs that are too short (under 90 s, or under 180 s for stays).
  5. Re-classify runs that had no motion data from their speed percentiles.
- **Places** (`Shared/Places.swift`, `web/static/js/places.js`): stays of 5 minutes or more cluster within 150 m. Home = most time between 22:00 and 06:00 (at least 4 h). Work = most weekday 9–17 time (at least 4 h, on 2+ days). The rest are ranked by total time.
- **Viewers:** the Mac app keeps everything in memory (`Mac/TrackLibrary.swift`) and uses MapKit with an `MKTileOverlay` for OSM tiles. The web app (`web/static/js/app.js`) uses Leaflet with a canvas renderer.

## 5. Real-device checklist (none of this has been verified yet)

1. **Background recording:** lock the phone, walk or drive 20 minutes, and check that History shows the trip. Then force-quit and check it again: force-quitting is expected to stop recording until the app is reopened, and that's documented.
2. **Always permission:** check that the upgrade prompt appears and that recording continues with the app closed.
3. **Airplane mode:** turn it on, walk outside, and check that points are still recorded (GPS only).
4. **Smart power:** check it rests while stationary and wakes on walking, and look at battery drain over a day in Settings → Battery.
5. **Timed mode:** set every 5 minutes and leave the phone in your pocket for an hour. Expect about 12 points, with the "Next point" countdown advancing.
6. **Pause:** 1 hour should resume by itself. Check that nothing is recorded during the pause.
7. **Siri and Shortcuts:** "Pause Pos XY", and a Shortcuts automation (e.g. CarPlay → Start Recording).
8. **Face ID lock:** it should lock on background, and cancelling shouldn't loop the prompt.
9. **Export:** make a locked export, AirDrop it to the Mac, open it in the Mac viewer and the web viewer with the passphrase, and check that place names appear.
10. **Activity tags:** a real drive, walk and bike ride should be labelled correctly. Trains are known to show as Drive.

## 6. Backlog (ideas, roughly by value)

- **Mac viewer parity with web:** overview, calendar, "Where was I?", renaming places (store names in the app's sandbox).
- **Privacy zones:** blur or hide points near chosen places in GPX/JSON exports meant for sharing.
- **iPhone history browsing:** a scrubber, and maybe pinch-zoom on the sketch.
- **Widget / Live Activity** showing recording status. This needs a new extension target, so edit the hand-written pbxproj carefully.
- **Weekly and monthly summaries** in the overview: distance by mode per week.
- **Battery:** use `CLLocationManager.startMonitoringVisits()` as an extra signal for stays.
- **Classification:** detect trains (high steady speed on rail corridors, without map data?), and better bike vs. city-drive separation without motion data.
- **Housekeeping:** delete the stray `claude/mac-viewer-smoke` branch; the cloud session's git proxy couldn't delete branches.

## 7. Facts that save time

- Bundle IDs: `io.github.gravelcycles.posxy` (iPhone) and `io.github.gravelcycles.posxy.viewer` (Mac). Schemes: `PosXY` and `PosXYViewer`. These are shared schemes, committed in `PosXY.xcodeproj/xcshareddata`.
- Mac app signing: ad-hoc (`CODE_SIGN_IDENTITY = -`), sandboxed with network-client, user-selected-read-only and downloads-read-only entitlements. A downloaded build needs right-click → Open the first time.
- iPhone Info.plist keys are in `Config/iOS-Info.plist`: background location, location/motion/Face ID usage strings, and `ITSAppUsesNonExemptEncryption = false`.
- CI simulator tests use UserDefaults launch arguments: `-recorder.isRecording YES -recorder.intervalSeconds 20`.
- Fixtures:
  - `web/tests/fixtures/sample-day.json`: one SF day, with a flight to LA.
  - `sample-day-every-*s.json`: the same day thinned to timed sampling.
  - `week.json`: home, work, café, gym, park.
  - `import/`: Google and GPX samples.
  - The generators are `make_fixture.py` and `make_week.py`.
- Web viewer storage: renamed place names live in `localStorage['posxy.placeNames']` on the localhost origin. **Forget all** clears them.
