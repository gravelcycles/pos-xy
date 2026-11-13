# Pos XY: notes for Claude

A private location history ("my own Google Maps Timeline"):
- **iPhone app** (`iOS/`) records GPS on-device, in airplane mode too, with no networking code at all. It exports passphrase-locked files over AirDrop.
- **Mac viewer** (`Mac/`) and **web viewer** (`web/`, served from localhost) show the history on OpenStreetMap.

**Start here:** read [`docs/HANDOFF.md`](docs/HANDOFF.md). It covers the current state, how to deploy to the owner's iPhone, what's verified and what isn't, and the backlog.

## Ground rules (the owner cares about these)
- **Privacy first.** The iPhone app must never make network requests. Don't add analytics, crash reporters, SDKs or third-party packages to the apps. The web viewer's CSP allows only `self` plus OSM tile images; keep it that way.
- **No third-party code in the apps.** Apple frameworks only. The web viewer vendors Leaflet 1.9.4 (in `web/static/vendor/`), and nothing else is loaded from the internet.
- **Two implementations of the core logic** must stay identical: Swift in `Shared/` (Segmenter, Places, Importers) and JS in `web/static/js/` (segmenter.js, places.js, importers.js). If you change one, change the other and run the parity checks.

## Layout
```
PosXY.xcodeproj   hand-written, objectVersion 77, "synchronized folder" groups (Xcode 16+)
Shared/           Swift used by BOTH apps: TrackPoint, ActivityType, Segmenter, Places, Importers, ExportCodec, Formatting
iOS/              iPhone app target "PosXY"   (bundle $(APP_BUNDLE_ID) = io.github.gravelcycles.posxy, iOS 17+)
iOSShared/        Swift compiled into BOTH PosXY and PosXYWidgets: RecordingStatus (App Group), control intents
Widgets/          widget extension target "PosXYWidgets" ($(APP_BUNDLE_ID).widgets, iOS 18+): status widget + controls
Mac/              Mac app target "PosXYViewer" (bundle io.github.gravelcycles.posxy.viewer, macOS 14+)
Config/           Info.plists (merged with generated keys) + Mac sandbox entitlements
web/              serve.py (stdlib) + static/ (index.html, app.css, js/, vendor/leaflet) + tests/
docs/             FORMAT.md (data format spec), pos-xy.schema.json, test-vectors/, DISTRIBUTION.md, HANDOFF.md
scripts/          deploy-iphone.sh, install-mac-viewer.sh, parity/run.sh, ci-simulator-run.sh, pretty.sh
.github/workflows ci.yml (build + simulator smoke test + Mac screenshot), testflight.yml (needs secrets)
```
- Add Swift files by dropping them into `Shared/`, `iOS/`, `iOSShared/`, `Widgets/` or `Mac/`; no project edits are needed. Never put an `Info.plist` inside those folders.
- **Bundle IDs:** the project-level `APP_BUNDLE_ID` drives the iPhone app, the widget extension (`.widgets`) and the App Group (`group.$(APP_BUNDLE_ID)`, also written into both Info.plists as `PosXYAppGroup`). Override `APP_BUNDLE_ID`, never `PRODUCT_BUNDLE_IDENTIFIER`, on the command line.
- **Widgets/controls:** the app publishes `RecordingStatus` (no coordinates) through `iOS/WidgetSync.swift`. The control intents conform to `LiveActivityIntent` so they run in the app's process; code that touches `LocationRecorder` in `iOSShared/` must sit inside `#if !WIDGET_EXTENSION`.
- The project uses Swift 5 language mode (`SWIFT_VERSION = 5.0`), not strict Swift 6 concurrency.

## Commands
```sh
node --test web/tests/*.test.mjs                    # 30 JS tests: format vectors, importers, segmenter + places goldens
scripts/parity/run.sh                               # Swift vs JS on every fixture (needs Xcode's swiftc + node)
python3 docs/test-vectors/make_vectors.py --check   # crypto vectors, independent impl (pip install cryptography)
python3 web/serve.py                                # web viewer on http://localhost:8765, lists ~/Downloads
scripts/deploy-iphone.sh                            # build, sign, install and launch on the connected iPhone
scripts/install-mac-viewer.sh                       # build the Mac viewer into /Applications
xcodebuild -project PosXY.xcodeproj -scheme PosXY -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PosXY.xcodeproj -scheme PosXYViewer -destination 'generic/platform=macOS' CODE_SIGN_IDENTITY=- build
```

## Gotchas
- **Golden tests:** `web/tests/segmenter.test.mjs` and `places.test.mjs` embed golden output produced by the Swift code. If you intentionally change the algorithm, regenerate the goldens from Swift (see the harnesses in `scripts/parity/`), not from JS.
- **Places and time zones:** place labels depend on the local time zone (night = 22–06 local). The places tests pin `TZ=America/Los_Angeles`.
- **Locked file format:** `.pxy` uses **raw DEFLATE**, which is Apple's `.zlib`, so browsers can read it. LZFSE would break the web viewer. Spec: `docs/FORMAT.md`.
- **CI runs cancel each other:** CI cancels an in-progress run on the same ref when you push again. The simulator step takes 6–15 minutes. Wait for green before pushing again if you need the result.
- **Git workflow:** the owner wants changes as PRs merged into `main` as you go.
