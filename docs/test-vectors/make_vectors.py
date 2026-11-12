#!/usr/bin/env python3
"""Generates the Pos XY format test vectors (docs/FORMAT.md §7).

Independent reference implementation of the locked container. Needs the `cryptography`
package (pip install cryptography) only to *regenerate* vectors; nothing at runtime uses it.
Run with --check to verify existing vectors instead of rewriting them.
"""
import hashlib, json, pathlib, sys, unicodedata, zlib
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

HERE = pathlib.Path(__file__).resolve().parent
MAGIC = b"PXYENC01"

def raw_deflate(data: bytes) -> bytes:
    c = zlib.compressobj(level=6, wbits=-15)          # wbits<0 = raw DEFLATE, no header
    return c.compress(data) + c.flush()

def raw_inflate(data: bytes) -> bytes:
    return zlib.decompress(data, wbits=-15)

def derive(passphrase: str, salt: bytes, iterations: int) -> bytes:
    pw = unicodedata.normalize("NFC", passphrase).encode("utf-8")
    return hashlib.pbkdf2_hmac("sha256", pw, salt, iterations, dklen=32)

def seal(plain: bytes, passphrase: str, salt: bytes, nonce: bytes, iterations: int) -> bytes:
    header = MAGIC + salt + iterations.to_bytes(4, "big")
    key = derive(passphrase, salt, iterations)
    return header + nonce + AESGCM(key).encrypt(nonce, raw_deflate(plain), header)

def open_(blob: bytes, passphrase: str) -> bytes:
    assert blob[:8] == MAGIC
    header, salt = blob[:28], blob[8:24]
    iterations = int.from_bytes(blob[24:28], "big")
    nonce, sealed = blob[28:40], blob[40:]
    return raw_inflate(AESGCM(derive(passphrase, salt, iterations)).decrypt(nonce, sealed, header))

PLAIN = {
    "format": "pos-xy", "version": 1, "exportedAt": 1762966800,
    "points": [
        {"t": 1762963200.0, "lat": 37.774929, "lon": -122.419416, "alt": 16.2, "acc": 5.0,
         "spd": 0.0, "act": "stationary"},
        {"t": 1762963260.5, "lat": 37.775312, "lon": -122.418927, "acc": 6.5, "spd": 1.41,
         "crs": 42, "act": "walking"},
        {"t": 1762963320.0, "lat": 37.776001, "lon": -122.418110},
    ],
}

VECTORS = [
    {"name": "vector-1", "passphrase": "correct horse battery staple",
     "salt": bytes(range(16)), "nonce": bytes(range(0xA0, 0xAC)), "iterations": 600_000},
    # Non-ASCII passphrase: stored NFC ("Zürich"); readers must also accept the decomposed
    # form "Zürich" because both normalise to the same bytes.
    {"name": "vector-2", "passphrase": "Zürich ✈ 2026",
     "salt": bytes.fromhex("f0e1d2c3b4a5968778695a4b3c2d1e0f"), "nonce": bytes.fromhex("0102030405060708090a0b0c"),
     "iterations": 1_000},
]

def main():
    check = "--check" in sys.argv
    plain = json.dumps(PLAIN, separators=(",", ":")).encode()
    meta = []
    for v in VECTORS:
        blob = seal(plain, v["passphrase"], v["salt"], v["nonce"], v["iterations"])
        path = HERE / f"{v['name']}.pxy"
        if check:
            on_disk = path.read_bytes()
            assert open_(on_disk, v["passphrase"]) == plain, f"{path.name}: does not decrypt"
            assert open_(on_disk, unicodedata.normalize("NFD", v["passphrase"])) == plain
            print(f"ok {path.name}")
            continue
        path.write_bytes(blob)
        meta.append({
            "file": path.name, "passphrase": v["passphrase"],
            "passphrase_nfc_utf8_hex": unicodedata.normalize("NFC", v["passphrase"]).encode().hex(),
            "salt_hex": v["salt"].hex(), "iterations": v["iterations"], "nonce_hex": v["nonce"].hex(),
            "key_hex": derive(v["passphrase"], v["salt"], v["iterations"]).hex(),
            "header_hex": blob[:28].hex(),
            "plaintext_file": "plaintext.json", "plaintext_sha256": hashlib.sha256(plain).hexdigest(),
            "file_sha256": hashlib.sha256(blob).hexdigest(), "file_length": len(blob),
        })
    if not check:
        (HERE / "plaintext.json").write_bytes(plain)
        (HERE / "vectors.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
        print(json.dumps(meta, indent=2, ensure_ascii=False))

if __name__ == "__main__":
    main()
