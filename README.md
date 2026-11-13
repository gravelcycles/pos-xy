# Pos XY

A private, on-device location history (your own "Google Maps Timeline"), in two parts:

- **Pos XY** (iPhone) records where you go, in the background and in airplane mode. It never touches the network.
- **Pos XY Viewer** (Mac app) shows a day on an OpenStreetMap map. Scrub through the day and see each trip labelled as walk, run, bike, drive, flight or stay.
- **Web viewer** (any browser, served from `localhost`) does the same with no Xcode build. Run one Python command.

You move data from phone to Mac by AirDrop. The file can be locked with a passphrase.

```
iPhone ──(AirDrop .pxy, AES-256 locked)──▶ Mac ~/Downloads ──▶ Pos XY Viewer (app)
                                                          └──▶ localhost web viewer (browser)
```

The file format is fully specified in [docs/FORMAT.md](docs/FORMAT.md), with test vectors.

## Install

> **Want it on your phone from a link?** See **[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md)**. With a paid Apple Developer account, a GitHub Action builds the app and sends it to TestFlight. Every push also builds both apps in CI, and tagged versions get downloads on GitHub Releases.

You need a Mac with **Xcode** (free, from the App Store). There's no way to put a home-made app on an iPhone without Xcode, short of the App Store or TestFlight.

### iPhone app

**Quickest:** plug in the iPhone and run `scripts/deploy-iphone.sh`. It finds your team and phone, builds, signs, installs and launches. If the bundle ID is taken: `BUNDLE_ID=com.yourname.posxy scripts/deploy-iphone.sh`.

**Or in Xcode:**
1. Open `PosXY.xcodeproj` in Xcode.
2. Select the **PosXY** target, open **Signing & Capabilities**, and pick your Apple ID under **Team** (Xcode → Settings → Accounts to add one). Do the same for the **PosXYWidgets** target. If Xcode says the bundle ID is taken, change the project's `APP_BUNDLE_ID` build setting (default `io.github.gravelcycles.posxy`) to anything unique; the widget extension follows it.
3. Plug in your iPhone (or use the same Wi-Fi), pick it as the run destination, and press **⌘R**.
4. First time only, on the iPhone:
   - Turn on **Settings → Privacy & Security → Developer Mode** and restart.
   - Allow the developer certificate under **Settings → General → VPN & Device Management**.
5. In the app, turn on **Record my location**. Choose **Allow While Using App**; iOS then asks right away whether to **Change to Always Allow**, so choose that. If you missed it, tap **Open Settings** in the app (or Settings → Apps → Pos XY → Location) and pick **Always**. Allow Motion & Fitness too, so it can tell walking from driving.

> **Free Apple ID:** apps you sideload expire after **7 days**. Re-run from Xcode to refresh. Your data is kept as long as you don't delete the app. A paid developer account ($99/yr) makes it last a year.

### Mac viewer

Either press **⌘R** in Xcode with the **PosXYViewer** scheme, or run:

```sh
./scripts/install-mac-viewer.sh     # builds Release and copies it to /Applications
```

No Apple ID is needed for the Mac app. It's signed to run locally.

### Web viewer (no build needed)

```sh
python3 web/serve.py             # opens http://localhost:8765 and lists exports in ~/Downloads
python3 web/serve.py --dir ~/Desktop/tracks --port 9000
```

It needs only Python 3 (included with Xcode's command line tools) and a modern browser: Safari 16.4+, Chrome 103+ or Firefox 113+. There's nothing to install: Leaflet, the map library, is vendored in `web/static/vendor/` at version 1.9.4, checked against npm's published SHA-512.

## Using it

**On the iPhone:** the main screen shows today's track as a local sketch, plus totals for walk, bike, drive and so on. **History** lists past days, each with its own sketch and trip timeline. Swipe a day to delete it.

**Export from the iPhone:** tap **Export & AirDrop to Mac**, choose a range, keep **Lock with a passphrase** on, and tap **Create export file**, then **Send via AirDrop…** and pick your Mac. The file lands in `~/Downloads`.

**View in the browser:** run `python3 web/serve.py`. Exports in `~/Downloads` appear in the left column; click one to load it, or drag files onto the page. Controls match the Mac app. ←/→ change day, Shift+←/→ jump 5 minutes, and space plays or pauses. Press `?` for all shortcuts.

The browser viewer also has:
- **Overview** (`O`): all your movement on one map, places sized by time spent, all-time totals per activity, and a calendar shaded by distance per day. Click a day to open it.
- **Where was I?** (`F`, or right-click the map): every visit near a spot across all your history. Click one to jump to that moment.
- **Places**: stays are labelled *Home*, *Work* or *Place N*. Click ✎ to rename one ("Gym", "Mom's"). Names are kept in this browser only, and **Forget all** removes them.
- **GPX export** of the day, or of everything, for other apps.
- **Bookmarkable days**: the address bar keeps the day (`#2026-11-12`) or `#overview`.

## Coming from Google Maps Timeline?

Every viewer (web, Mac) opens Google's location exports directly. Nothing is uploaded; they're parsed locally.

| Export | How to get it | File |
| --- | --- | --- |
| Google Maps Timeline, Android | Settings → Location → Location services → Timeline → *Export Timeline data* | `Timeline.json` |
| Google Maps Timeline, iPhone | Google Maps → your profile → Settings → Personal content → *Export Timeline data* | `location-history.json` |
| Classic Google Takeout | takeout.google.com → Location History | `Records.json` |
| Any GPS watch / bike computer / app | Export as GPX | `*.gpx` |

Drop the file on the web viewer (or open it in the Mac app), and it merges with your Pos XY data. Google's activity types (walking, in passenger vehicle, cycling…) become Pos XY activities.

**View in the Mac app:** double-click the `.pxy` file, drag it onto the viewer window, or press ⌘O. You can open several exports at once; they're merged and de-duplicated. If they share a passphrase you only type it once.

| Viewer control | What it does |
| --- | --- |
| Sidebar | Days that have data, grouped by month |
| ⌘← / ⌘→ | Previous / next day |
| Coloured bar | The day as a timeline. Click or drag on it to scrub |
| Slider, ▶︎ (space) | Scrub, or play the day back at 1 min to 1 h per second |
| Follow | Keep the map centred on the moving marker |
| Timeline list | Click a trip to zoom the map to it |

The track up to the playhead is drawn in colour and the rest faded. Stays are purple circles. Flights and unknown gaps are dashed.

## Places

Pos XY finds the places you keep coming back to, on the device or viewer, from your own data:
- **Clustering:** stays of 5 minutes or more within 150 m of each other become one place.
- **Home** is where you spend the most night time (22:00–06:00), if it adds up to at least 4 hours.
- **Work** is where you spend the most weekday office hours (Mon–Fri 9–17), with at least 4 hours over 2 or more days.
- **Everything else** is *Place 1, 2, …* by total time. One-off short stops stay unnamed.

You'll see the names in every timeline: the iPhone's Today view (e.g. "Home → Place 2 → Work → Home"), History, the Mac app, and the web viewer. It's the same algorithm in Swift (`Shared/Places.swift`) and JS (`web/static/js/places.js`), and a test keeps their output identical.

## Privacy

**iPhone**
- No network code at all. The app doesn't show a map on the phone (that would send your area to a tile server); the "Today" view is drawn locally.
- Points are stored as one file per day in the app's private container, using iOS **Data Protection**, which encrypts with a key tied to your passcode. The class is `completeUntilFirstUserAuthentication` so recording can continue while the phone is locked.
- History is excluded from iCloud and Finder backups. Deleting the app deletes it.
- Optional **Require Face ID** lock for the app's screen. Recording continues while it's locked.
- **Delete all history** wipes everything.
- Lock Screen widgets and controls only show on/paused/off, today's point count and the last fix time. No locations.

**Export files**
- `.pxy` = AES-256-GCM, key from your passphrase via PBKDF2-HMAC-SHA256 with 600,000 rounds and a random salt. The header is authenticated, so tampering is detected. A forgotten passphrase can't be recovered.
- With the lock off you get plain `.json`. Anyone who gets it can read it.

**Mac viewer**
- Keeps your history **in memory only**. Quit it and it's gone. Your original files stay wherever you put them.
- The only network traffic is map tiles from `tile.openstreetmap.org`. That server sees which map areas you look at, as with any web map. Tiles are cached on disk (up to 512 MB) so areas you revisit aren't requested again.

**Web viewer**
- `serve.py` listens on `127.0.0.1` only. It refuses requests whose `Host` isn't `localhost` (which blocks DNS-rebinding attacks), serves only export-looking files from the chosen folder by bare name (no paths), never lists directories, and makes no outbound requests itself.
- Decryption happens in the browser tab with Web Crypto. The passphrase never reaches the server.
- The page's Content-Security-Policy forbids connecting to anything except `localhost`, and forbids loading images from anywhere except `tile.openstreetmap.org`. So even a bug couldn't send your data elsewhere.
- Loaded data lives only in the tab's memory. Close the tab, or click **Forget all**.

## Airplane mode and flights

GPS is receive-only, so it works in airplane mode and on flights with no network. Expect:
- Fixes take longer without a network (no assisted GPS). A window seat helps a lot. In an aisle seat you may get nothing until landing.
- Use **GPS mode → Always precise** for a flight. **Smart** mode rests the GPS when the motion chip says you're still, and smooth cruising can feel "still" to it. The app also won't rest the GPS within 10 minutes of a fast fix, as a safeguard.
- If there are no fixes for the whole flight, the viewer still draws a dashed **Flight** from the last fix before takeoff to the first one after landing. It does this whenever there's a long silence with an implied speed over 180 km/h.

## How activities are classified

1. On the phone, each fix is tagged with iOS's motion classification (walking, running, cycling, automotive or stationary) when it's at least medium confidence.
2. In the viewer (and the phone's "Today" summary), each point's tag is checked against its speed. Over 216 km/h is always a flight, and a "walk" at 50 km/h is overruled.
3. Labels are smoothed with a ±60 s majority vote. Blips shorter than 90 s (3 min for stays) are merged into the surrounding trip, so a red light stays part of the drive.
4. Trips recorded without motion data (or imported from elsewhere) are classified from their speed profile: median and 90th percentile.
5. Silences longer than 5 minutes become a **stay** (moved less than 300 m), a **flight** (implied speed over 180 km/h), or an unknown dashed gap.

It's heuristic. Trains usually show up as **Drive**.

## Pause, Siri and Shortcuts

- **Pause recording…** on the main screen stops recording for 1 hour, 4 hours, or until 7:00 tomorrow, then resumes by itself. Use it for places you'd rather not have in your history. Nothing is recorded while paused, and the GPS stays off.
- **Siri and Shortcuts:** *Start Recording*, *Stop Recording* and *Pause Recording* (for N hours) show up in the Shortcuts app and work with Siri ("Pause Pos XY"). Pair them with automations, for example *When CarPlay connects → Start Recording*, or *When I arrive at [place] → Pause Recording*.
- The Export row shows when you last made an export, as a reminder to back up.

## Lock Screen, Control Center and the Action button (iOS 18)

- **Controls:** *Record Location* (on/off) and *Pause for 1 Hour* (tap again to resume). Add them to **Control Center** (swipe down → hold → Add a Control → Pos XY), to the **Lock Screen**'s bottom buttons (hold the Lock Screen → Customize → Lock Screen → tap a button), or to the **Action button** (Settings → Action Button → Controls → Pos XY).
- **Recording Status widget:** on the Lock Screen (circular, rectangular, or the line above the clock) and the Home Screen (small, with a Record/Stop button). It shows whether Pos XY is recording or paused, how many points it took today, and how long ago the last fix was.
- The widgets show no coordinates or place names, since anyone holding the phone can see the Lock Screen. The app shares just that status with its widget extension through a keychain item that never leaves the iPhone.

## Recording frequency

On the phone, **Frequency → Record a point**:

| Setting | What it does | Battery |
| --- | --- | --- |
| **Continuously** (default) | A point about every 15 m you move. Best walk/bike/drive detection. | Highest while moving. Smart mode rests the GPS when you're still. |
| **Every minute / 5 minutes / 15 minutes / hour** | One GPS point on that schedule. | Much lower: the GPS is off between points. |
| **Custom…** | Any interval from 10 seconds to 12 hours. | |

Between timed points the app keeps only a coarse location session open (no GPS). That costs very little, and it's what lets iOS wake the app on time. For each point it turns the GPS on until it gets a good fix (up to 90 s, which helps in airplane mode), saves the best one, and turns it off again.

The viewers adapt automatically. A silence only counts as a gap when it's longer than 2.5× the typical spacing between points, so a 15-minute schedule still gives walk/drive/flight segments rather than a row of unknown gaps. `web/tests` checks the same day sampled every 1, 5, 15 and 60 minutes against the Swift results.

## Battery

Smart mode uses full GPS while you're moving (a point every 15 m) and drops to coarse location when the motion chip says you're stationary. Most of the battery cost is GPS time while moving, so it depends on how much you travel. iOS also relaunches the app after a reboot once you've moved about 500 m. **Don't force-quit it** from the app switcher: that stops background recording until you open it again.

## File format

See **[docs/FORMAT.md](docs/FORMAT.md)** for the full spec: point fields and units, the export document, the phone's day files, the locked `.pxy` byte layout (PBKDF2-SHA256 → AES-256-GCM over raw-DEFLATE JSON), and the reader rules. There's a JSON Schema in [docs/pos-xy.schema.json](docs/pos-xy.schema.json) and test vectors in [docs/test-vectors/](docs/test-vectors/).

In short, a plain export looks like this:

```json
{ "format": "pos-xy", "version": 1, "exportedAt": 1762990000,
  "points": [ { "t": 1762950000.0, "lat": 37.774929, "lon": -122.419416,
                "alt": 12.3, "acc": 5.0, "spd": 1.42, "crs": 270, "act": "walking" } ] }
```

## Tests

```sh
node --test web/tests/*.test.mjs                    # web reader vs. test vectors, segmenter vs. Swift golden output
python3 docs/test-vectors/make_vectors.py --check   # independent Python implementation (needs: pip install cryptography)
```

The segmenter exists twice, in `Shared/Segmenter.swift` (both apps) and `web/static/js/segmenter.js`. `web/tests/segmenter.test.mjs` pins the JS output to golden values produced by the Swift code. Keep the two in sync.

## Dependencies

No third-party code in the apps. Both use only Apple's built-in frameworks: SwiftUI, CoreLocation, CoreMotion, CryptoKit, CommonCrypto, LocalAuthentication, and MapKit (Mac only). There are no third-party packages, analytics or crash reporters. The iPhone app contains no networking code, so it can't send your location anywhere. On the Mac, MapKit is only the map widget: Apple's map content is replaced by OSM tiles, and "show my location" is never turned on. The web viewer uses Leaflet, a widely used open-source map library vendored in the repo. It makes no network requests except loading the tile images you see.

## Project layout

```
Shared/   models, activity segmentation, export encryption (used by both apps)
iOS/      recorder app: CoreLocation + CoreMotion, storage, export, Face ID lock
iOSShared/  recording status + control intents (compiled into the app and the widget extension)
Widgets/  widget extension: Lock Screen/Home Screen status widget, Control Center/Action button controls
Mac/      viewer app: MapKit + OpenStreetMap tiles, timeline, trip list
Config/   Info.plists and Mac sandbox entitlements
Shared/   …also Places.swift (Home/Work detection) and Importers.swift (Google Timeline, GPX)
web/      localhost web viewer: serve.py (stdlib only) + static/ (HTML, JS, vendored Leaflet) + tests/
docs/     FORMAT.md spec, JSON Schema, test vectors
```

Requires iOS 17+ and macOS 14+. Built with Xcode 16 or newer.
