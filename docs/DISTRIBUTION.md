# Getting Pos XY onto your devices

| You have | iPhone | Mac viewer |
| --- | --- | --- |
| **Paid Apple Developer account** ($99/yr) | **TestFlight**: GitHub builds and uploads it, and you tap *Install* in the TestFlight app. Builds last 90 days. | Download from a GitHub Release, or the web viewer. |
| **Free Apple ID** | Xcode + cable (re-run every 7 days), or the unsigned `.ipa` from CI + a sideloading tool. | Same as above. |
| **No Mac at hand** | TestFlight (paid) only. | Web viewer on any computer with Python. |

Apple only lets an iPhone install apps signed with a certificate Apple issued. A free Apple ID gets a 7-day certificate, and only through Xcode or tools that log in as you. So "click a link and install" means TestFlight, which needs the paid program.

---

## What CI does on every push

`.github/workflows/ci.yml`, on a GitHub macOS runner:

1. Runs the format and segmenter tests (`web/tests`) and checks the test vectors against the independent Python implementation.
2. Builds the **Mac viewer** (Release, signed to run locally) and the **iPhone app** (Release, unsigned).
3. Builds the iPhone app for the **simulator**, installs it, grants location permission, turns recording on, and simulates a drive plus a short walk across San Francisco. It then checks that points were recorded and saves a screenshot and the recorded day file.
4. Parses that recorded file with the web viewer's reader and segmenter.
5. Uploads artifacts:
   - `apps`: `PosXYViewer-mac.zip` and `PosXY-unsigned.ipa`
   - `simulator-run`: the screenshot and the `.jsonl`

Push a tag such as `v0.1.0` and the same files are attached to a **GitHub Release**, which gives you a permanent download link:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

## Mac viewer from a download

1. Download `PosXYViewer-mac.zip` from the Release (or the `apps` artifact on a CI run) and unzip it.
2. Move `PosXYViewer.app` to Applications.
3. The first time, **right-click → Open → Open**. It's not notarized, because notarizing needs the paid account. On recent macOS, if there's no Open button: System Settings → Privacy & Security → *Open Anyway*.

---

## iPhone via TestFlight (paid account)

### One-time setup (about 15 minutes)

1. **Join the Apple Developer Program** at developer.apple.com/programs. Approval can take a day.
2. **Register the bundle ID.** On developer.apple.com go to Certificates, IDs & Profiles → Identifiers → **+** → App IDs → App, and choose an *Explicit* Bundle ID. The default is `io.github.gravelcycles.posxy`; if you pick a different one, set it as the repo variable `IOS_BUNDLE_ID` (step 6). Don't add any capabilities: background location needs only the Info.plist entries already in the project.
3. **Create the app record.** In App Store Connect → Apps → **+** → New App: platform iOS, any name (it must be unique on the App Store, e.g. "Pos XY Private"), the bundle ID from step 2, any SKU. Nothing is published; this just gives TestFlight somewhere to put builds.
4. **Create an API key.** In App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys → **+**:
   - Access: **Admin**. Apple's cloud signing needs Admin to create the signing certificate and provisioning profile for you.
   - Download the `.p8` file. You can only download it once.
   - Note the **Key ID**, and the **Issuer ID** shown above the key list.
5. **Find your Team ID** on developer.apple.com → Account → Membership details. It's 10 characters.
6. **Add GitHub secrets.** In the repo go to Settings → Secrets and variables → Actions → *New repository secret*:

   | Secret | Value |
   | --- | --- |
   | `ASC_KEY_ID` | Key ID from step 4 |
   | `ASC_ISSUER_ID` | Issuer ID from step 4 |
   | `ASC_KEY_P8` | The whole contents of the `.p8` file, including the `-----BEGIN PRIVATE KEY-----` lines |
   | `APPLE_TEAM_ID` | Team ID from step 5 |

   Optional: under the *Variables* tab, add `IOS_BUNDLE_ID` if you didn't use the default.
7. **Add yourself as a tester.** In App Store Connect → your app → TestFlight → Internal Testing → **+** create a group, then add yourself. Install the **TestFlight** app on your iPhone and sign in with the same Apple ID.

### Each time you want a build on your phone

GitHub → **Actions → TestFlight → Run workflow**. About 10 minutes later, plus Apple's processing time (usually 5–15 minutes), the build appears in TestFlight on your phone. Tap **Install**, or turn on automatic updates.

Notes:
- Internal TestFlight builds don't go through App Review, so the always-on background location is fine. Builds expire after 90 days; run the workflow again for a fresh one.
- Each run's build number is the workflow run number, so uploads never collide.
- Signing is fully automatic. Xcode on the runner uses the API key to create and download the certificate and profile ("cloud signing"), so you never export certificates. If a run fails at signing, the job uploads `testflight-logs`. The usual causes are a key without Admin access, a bundle ID that doesn't match the app record, or an unaccepted agreement in App Store Connect → Business.
- Your TestFlight data stays on your phone. TestFlight can send crash reports to *you* (the developer); you can turn that off in TestFlight's settings.

---

## iPhone with a free Apple ID

### Option A: Xcode and a cable (simplest)
Follow the README's *Install → iPhone app* steps. Re-run from Xcode every 7 days; your recorded data survives.

### Option B: sideload the CI build
CI produces `PosXY-unsigned.ipa`. Tools such as **SideStore**, **AltStore** or **Sideloadly** re-sign an `.ipa` with your free Apple ID and install it. They also refresh the 7-day signature, either over Wi-Fi or on the phone itself with SideStore.
- These are third-party tools that log in to Apple with your Apple ID, so decide whether you trust them first. Pos XY itself doesn't need them.
- In the EU, AltStore PAL is an approved alternative app marketplace. It doesn't install arbitrary `.ipa` files, though.
