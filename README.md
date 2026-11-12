# Pos XY

A private, on-device location history (your own "Google Maps Timeline"), in two parts:

- **Pos XY** (iPhone) records where you go, in the background and in airplane mode. It never touches the network.
- **Pos XY Viewer** (Mac) shows a day on an OpenStreetMap map. Scrub through the day and see each trip labelled as walk, run, bike, drive, flight or stay.

You move data from phone to Mac by AirDrop. The file can be locked with a passphrase.

```
iPhone ──(AirDrop .pxy, AES-256 locked)──▶ Mac ~/Downloads ──▶ Pos XY Viewer
```

## Install

You need a Mac with **Xcode** (free, from the App Store). There's no way to put a home-made app on an iPhone without Xcode, short of the App Store or TestFlight.

### iPhone app

1. Open `PosXY.xcodeproj` in Xcode.
2. Select the **PosXY** target, open **Signing & Capabilities**, and pick your Apple ID under **Team** (Xcode → Settings → Accounts to add one). If Xcode says the bundle ID is taken, change `io.github.gravelcycles.posxy` to anything unique.
3. Plug in your iPhone (or use the same Wi-Fi), pick it as the run destination, and press **⌘R**.
4. First time only, on the iPhone:
   - Turn on **Settings → Privacy & Security → Developer Mode** and restart.
   - Allow the developer certificate under **Settings → General → VPN & Device Management**.
5. In the app, turn on **Record my location**. When iOS asks, allow location. Later, choose **Change to Always Allow** (or set it in Settings → Pos XY → Location → Always). Allow Motion & Fitness too, so it can tell walking from driving.

> **Free Apple ID:** apps you sideload expire after **7 days**. Re-run from Xcode to refresh. Your data is kept as long as you don't delete the app. A paid developer account ($99/yr) makes it last a year.

### Mac viewer

Either press **⌘R** in Xcode with the **PosXYViewer** scheme, or run:

```sh
./scripts/install-mac-viewer.sh     # builds Release and copies it to /Applications
```

No Apple ID is needed for the Mac app. It's signed to run locally.

## Using it

**On the iPhone:** the main screen shows today's track as a local sketch, plus totals for walk, bike, drive and so on. **History** lists past days, each with its own sketch and trip timeline. Swipe a day to delete it.

**Export from the iPhone:** tap **Export & AirDrop to Mac**, choose a range, keep **Lock with a passphrase** on, and tap **Create export file**, then **Send via AirDrop…** and pick your Mac. The file lands in `~/Downloads`.

**View on the Mac:** double-click the `.pxy` file, drag it onto the viewer window, or press ⌘O. You can open several exports at once; they're merged and de-duplicated. If they share a passphrase you only type it once.

| Viewer control | What it does |
| --- | --- |
| Sidebar | Days that have data, grouped by month |
| ⌘← / ⌘→ | Previous / next day |
| Coloured bar | The day as a timeline. Click or drag on it to scrub |
| Slider, ▶︎ (space) | Scrub, or play the day back at 1 min to 1 h per second |
| Follow | Keep the map centred on the moving marker |
| Timeline list | Click a trip to zoom the map to it |

The track up to the playhead is drawn in colour and the rest faded. Stays are purple circles. Flights and unknown gaps are dashed.

## Privacy

**iPhone**
- No network code at all. The app doesn't show a map on the phone (that would send your area to a tile server); the "Today" view is drawn locally.
- Points are stored as one file per day in the app's private container, using iOS **Data Protection**, which encrypts with a key tied to your passcode. The class is `completeUntilFirstUserAuthentication` so recording can continue while the phone is locked.
- History is excluded from iCloud and Finder backups. Deleting the app deletes it.
- Optional **Require Face ID** lock for the app's screen. Recording continues while it's locked.
- **Delete all history** wipes everything.

**Export files**
- `.pxy` = AES-256-GCM, key from your passphrase via PBKDF2-HMAC-SHA256 with 600,000 rounds and a random salt. The header is authenticated, so tampering is detected. A forgotten passphrase can't be recovered.
- With the lock off you get plain `.json`. Anyone who gets it can read it.

**Mac viewer**
- Keeps your history **in memory only**. Quit it and it's gone. Your original files stay wherever you put them.
- The only network traffic is map tiles from `tile.openstreetmap.org`. That server sees which map areas you look at, as with any web map. Tiles are cached on disk (up to 512 MB) so areas you revisit aren't requested again.

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

## Battery

Smart mode uses full GPS while you're moving (a point every 15 m) and drops to coarse location when the motion chip says you're stationary. Most of the battery cost is GPS time while moving, so it depends on how much you travel. iOS also relaunches the app after a reboot once you've moved about 500 m. **Don't force-quit it** from the app switcher: that stops background recording until you open it again.

## File format

The plain export (`.json`):

```json
{ "format": "pos-xy", "version": 1, "exportedAt": 1762990000,
  "points": [ { "t": 1762950000.0, "lat": 37.774929, "lon": -122.419416,
                "alt": 12.3, "acc": 5.0, "spd": 1.42, "crs": 270, "act": "walking" } ] }
```

`t` is Unix time; `alt`, `acc`, `spd`, `crs` and `act` are optional. `act` is one of `stationary`, `walking`, `running`, `cycling`, `driving`.

Locked export (`.pxy`): `"PXYENC01"` ‖ salt (16 B) ‖ PBKDF2 rounds (UInt32, big-endian) ‖ AES-GCM nonce ‖ ciphertext ‖ tag (16 B). The first 28 bytes are the GCM associated data. The plaintext is the JSON above, LZFSE-compressed.

The viewer also opens bare JSON arrays of points and the phone's raw per-day `.jsonl` files.

## Dependencies

None. Both apps use only Apple's built-in frameworks: SwiftUI, CoreLocation, CoreMotion, CryptoKit, CommonCrypto, LocalAuthentication, and MapKit (Mac only). There are no third-party packages, analytics or crash reporters. The iPhone app contains no networking code, so it can't send your location anywhere. On the Mac, MapKit is only the map widget: Apple's map content is replaced by OSM tiles, and "show my location" is never turned on.

## Project layout

```
Shared/   models, activity segmentation, export encryption (used by both apps)
iOS/      recorder app: CoreLocation + CoreMotion, storage, export, Face ID lock
Mac/      viewer app: MapKit + OpenStreetMap tiles, timeline, trip list
Config/   Info.plists and Mac sandbox entitlements
```

Requires iOS 17+ and macOS 14+. Built with Xcode 16 or newer.
