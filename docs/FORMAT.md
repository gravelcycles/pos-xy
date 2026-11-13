# Pos XY data format, version 1

This document specifies the files the Pos XY iPhone app writes and the viewers (Mac app and web viewer) read. Anyone can write a compatible reader or writer from this document alone.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

| File | Extension | What it is |
| --- | --- | --- |
| Export | `.json` | An export document (§3) as UTF-8 JSON. |
| Locked export | `.pxy` | An export document, compressed and encrypted with a passphrase (§5). |
| Day file | `.jsonl` | The phone's internal storage: one point per line (§4). Not normally shared. |

Reference implementations:

| Role | Code |
| --- | --- |
| Writer | `Shared/ExportCodec.swift` (CryptoKit + CommonCrypto) |
| Readers | `Shared/ExportCodec.swift`, `web/static/js/format.js` (Web Crypto) |
| Independent implementation (made the test vectors) | `docs/test-vectors/make_vectors.py` (Python `cryptography`) |

A JSON Schema for §2–§3 is in [`pos-xy.schema.json`](pos-xy.schema.json).

---

## 1. Conventions

- **Time** is Unix time: seconds since 1970-01-01T00:00:00Z, as a JSON number. Fractions are allowed (writers SHOULD keep at most millisecond precision). Time zones are not stored. Readers group points into days using the viewer's local time zone.
- **Coordinates** are WGS 84 decimal degrees. Writers SHOULD round latitude and longitude to 6 decimal places (about 11 cm).
- **JSON** is UTF-8, RFC 8259. Writers MUST NOT emit `NaN` or `Infinity`.
- **Sampling** is irregular. The phone can record continuously (seconds apart) or on a schedule (every N minutes, §README "Recording frequency"). Readers MUST NOT assume a fixed spacing between points.
- **Absent vs. null:** writers MUST omit unknown optional fields rather than writing `null`. Readers MUST treat `null` the same as absent.

## 2. Point

A point is a JSON object recording one location fix.

| Key | Type | Required | Unit / meaning |
| --- | --- | --- | --- |
| `t` | number | **yes** | Time of the fix (§1). |
| `lat` | number | **yes** | Latitude, −90…90. |
| `lon` | number | **yes** | Longitude, −180…180. |
| `alt` | number | no | Altitude above mean sea level, metres. Omitted if the device had no vertical fix. |
| `acc` | number | no | Horizontal accuracy, metres: radius of 68 % confidence, as reported by iOS. |
| `spd` | number | no | Ground speed from the GNSS chip, m/s, ≥ 0. Omitted when unknown (iOS reports −1). |
| `crs` | number | no | Course over ground, degrees clockwise from true north, 0 ≤ crs < 360. Omitted when unknown. |
| `act` | string | no | What the motion coprocessor thought was happening at that moment (see below). |

`act` values:

| Value | Meaning |
| --- | --- |
| `stationary` | Not moving. |
| `walking` | On foot, walking. |
| `running` | On foot, running. |
| `cycling` | On a bicycle. |
| `driving` | In a vehicle. iOS's "automotive" includes being stopped in traffic. |
| `flying` | Reserved. The phone never writes it; viewers infer flights from speed. |
| `unknown` | Unclassified. Equivalent to absent. |

The phone records `act` only when iOS reports at least medium confidence. Viewers treat it as a hint and re-check it against speed (see the README, "How activities are classified").

**Reader rules:**
- Readers MUST ignore keys they don't recognise, so future versions can add fields.
- Readers MUST map an unrecognised `act` string to `unknown`.
- Readers SHOULD drop points that have no finite `t`, `lat` or `lon`, or whose `lat`/`lon` are out of range.
- Points MAY appear in any order and MAY be duplicated (the same `t` in two overlapping exports). Readers SHOULD sort by `t` and de-duplicate on `t` rounded to the millisecond, keeping the first.

Example:

```json
{"t":1762963260.5,"lat":37.775312,"lon":-122.418927,"acc":6.5,"spd":1.41,"crs":42,"act":"walking"}
```

## 3. Export document (`.json`)

```json
{
  "format": "pos-xy",
  "version": 1,
  "exportedAt": 1762966800,
  "points": [ { "t": 1762963200.0, "lat": 37.774929, "lon": -122.419416 } ]
}
```

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `format` | string | **yes** | Always `"pos-xy"`. |
| `version` | integer | **yes** | Format version. This document describes `1`. |
| `exportedAt` | number | no | Unix time the file was written. |
| `points` | array of Point | **yes** | Any number of points, any order. |

**Versioning:**
- A change that only adds optional keys keeps `version` at 1.
- A change that alters the meaning of an existing key, or adds a required one, increments `version`.
- Readers SHOULD read files with a higher `version` on a best-effort basis (warn, then read what they understand) rather than refusing them.

**Lenient inputs:** for convenience, readers SHOULD also accept a bare JSON array of points, and JSON Lines (§4). The Pos XY viewers also import Google Maps Timeline / Takeout JSON and GPX. Those are converted to points on load and aren't part of this format (see `Shared/Importers.swift`).

## 4. Day file (`.jsonl`)

On the phone, points are appended to one file per local calendar day, named `YYYY-MM-DD.jsonl`, in the app's private `Application Support/Tracks/` folder. Each line is one Point object (§2) followed by `\n` (0x0A). There is no header line.

Readers MUST skip lines that fail to parse: the last line may be truncated if the app was killed mid-write.

## 5. Locked export (`.pxy`)

A locked export protects an export document with a passphrase. It provides confidentiality and integrity: any change to any byte, including the header, makes decryption fail.

### 5.1 Byte layout

| Offset | Length | Field |
| --- | --- | --- |
| 0 | 8 | `magic` = ASCII `PXYENC01` (`50 58 59 45 4E 43 30 31`) |
| 8 | 16 | `salt`: random |
| 24 | 4 | `iterations`: unsigned 32-bit, big-endian |
| 28 | 12 | `nonce`: random |
| 40 | n | `ciphertext` |
| 40 + n | 16 | `tag`: GCM authentication tag |

`header` means bytes 0–27 (magic, salt and iterations). The smallest valid file is 56 bytes (empty ciphertext).

Bytes 28 to the end are exactly CryptoKit's `AES.GCM.SealedBox.combined` representation: nonce ‖ ciphertext ‖ tag.

### 5.2 Key derivation

```
password = UTF-8( NFC( passphrase ) )
key      = PBKDF2-HMAC-SHA256( password, salt, iterations, dkLen = 32 )
```

- **NFC:** the passphrase MUST be Unicode-normalised to NFC before UTF-8 encoding, so the same passphrase typed on different keyboards or systems gives the same bytes. Swift: `precomposedStringWithCanonicalMapping`. JavaScript: `normalize('NFC')`. Python: `unicodedata.normalize('NFC', …)`.
- **Passphrase rules:** the passphrase MUST NOT be empty. The iPhone app requires at least 6 characters.
- **Iterations:** writers MUST use at least 100,000. The iPhone app writes 600,000. Readers MUST reject values below 1,000 or above 50,000,000 (to avoid hanging on a corrupt header).

### 5.3 Encryption

```
plaintext  = raw_deflate( UTF-8 JSON export document (§3) )
ciphertext ‖ tag = AES-256-GCM-Encrypt( key, nonce, plaintext, associated_data = header )
```

- **Compression** is raw DEFLATE, RFC 1951: no zlib (RFC 1950) or gzip (RFC 1952) wrapper.
  - Apple: `NSData.compressed(using: .zlib)`. Apple's "zlib" algorithm emits raw DEFLATE.
  - Browsers: `DecompressionStream('deflate-raw')`.
  - Python: `zlib` with `wbits = -15`.
- **Associated data:** the 28-byte header is authenticated. Changing the salt or iteration count is detected.
- **Randomness:** writers MUST generate `salt` and `nonce` with a CSPRNG and MUST NOT reuse a (key, nonce) pair. A fresh random salt per file gives a fresh key, which satisfies this.
- **Tag:** 128 bits.

### 5.4 Reading

1. If the file doesn't start with `magic`, it isn't locked; parse it as JSON (§3).
2. Check the length is ≥ 56 and the iteration count is in range; otherwise report "unreadable".
3. Derive the key (§5.2) and decrypt with the header as associated data.
4. Authentication failure means a wrong passphrase *or* a damaged file. The two can't be told apart, and readers SHOULD say so.
5. Inflate (raw DEFLATE), then parse as §3.

Readers SHOULD try a passphrase that already worked in the current session on further locked files before prompting, since people reuse one passphrase across exports.

### 5.5 What is *not* protected

- **File size** is not hidden: it roughly reveals how many points are inside.
- **File name** (e.g. `PosXY 2026-11-06 to 2026-11-12.pxy`) is not encrypted and reveals the date range. Rename the file if that matters.
- Strength depends on the passphrase. 600,000 PBKDF2 rounds slow down guessing, but a short or common passphrase can still be brute-forced offline. Use a long one.

## 6. Names and types

| | Value |
| --- | --- |
| Extensions | `.pxy` (locked), `.json` (plain), `.jsonl` (day file) |
| Uniform Type Identifier (`.pxy`) | `io.github.gravelcycles.posxy.track`, conforms to `public.data` |
| MIME type | `application/octet-stream` for `.pxy`; `application/json` for `.json` |
| Default export name | `PosXY YYYY-MM-DD.ext` (single day) or `PosXY YYYY-MM-DD to YYYY-MM-DD.ext` |

## 7. Test vectors

[`test-vectors/`](test-vectors/) contains:

| File | Contents |
| --- | --- |
| `plaintext.json` | A 3-point export document (the plaintext of both vectors). |
| `vector-1.pxy` | Passphrase `correct horse battery staple`, 600,000 iterations. |
| `vector-2.pxy` | Passphrase `Zürich ✈ 2026` (non-ASCII; readers must also accept its NFD form), 1,000 iterations. |
| `vectors.json` | Every intermediate value: salt, iterations, nonce, derived key, header, and SHA-256 of the plaintext and the file. |

Vector 1, abbreviated:

```
salt       000102030405060708090a0b0c0d0e0f
iterations 600000            (bytes 000927c0)
key        ef177144eec9420cbc1093d2a8b344a92bc506d0d4ec9c028dd19f8324d8c1e6
nonce      a0a1a2a3a4a5a6a7a8a9aaab
header     505859454e433031 000102030405060708090a0b0c0d0e0f 000927c0
```

DEFLATE output isn't unique: different compressors produce different bytes. So a writer is only expected to reproduce the *key* and *header* exactly. Every reader MUST decrypt both vector files to `plaintext.json`.

Check implementations with:

```sh
python3 docs/test-vectors/make_vectors.py --check   # independent Python implementation
node --test web/tests/*.test.mjs                     # web viewer reader
```

## 8. Changelog

- **1** (2026-11): first version.
