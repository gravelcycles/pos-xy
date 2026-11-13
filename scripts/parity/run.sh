#!/bin/bash
# Checks that the Swift (Shared/) and JavaScript (web/static/js/) implementations agree on every
# fixture: segmenter, places and importers. Run after changing either side.
#   scripts/parity/run.sh            (needs swiftc — Xcode on a Mac — and node)
# SWIFTC=/path/to/swiftc overrides the compiler.
set -euo pipefail
cd "$(dirname "$0")/../.."
SWIFTC="${SWIFTC:-swiftc}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
S=Shared
fail=0

build() {  # name, extra Shared files...
  local name=$1; shift
  mkdir -p "$OUT/$name"
  cp "scripts/parity/$name.swift" "$OUT/$name/main.swift"
  "$SWIFTC" -O -swift-version 5 "$@" "$OUT/$name/main.swift" -o "$OUT/$name/bin" 2>&1 | grep -E "error" || true
  [ -x "$OUT/$name/bin" ] || { echo "Swift build failed: $name"; exit 1; }
}
check() {  # label, swift output file, js output file
  if diff -q "$2" "$3" >/dev/null; then echo "OK        $1"; else echo "MISMATCH  $1"; diff "$2" "$3" | head -20; fail=1; fi
}

build segments $S/TrackPoint.swift $S/ActivityType.swift $S/Segmenter.swift
build places   $S/TrackPoint.swift $S/ActivityType.swift $S/Segmenter.swift $S/Places.swift
build imports  $S/TrackPoint.swift $S/ActivityType.swift $S/Importers.swift

for f in web/tests/fixtures/sample-day*.json web/tests/fixtures/week.json; do
  "$OUT/segments/bin" "$f" > "$OUT/s.txt"; node web/tests/parity.mjs "$f" > "$OUT/j.txt"
  check "segments  $(basename "$f")" "$OUT/s.txt" "$OUT/j.txt"
done
for tz in America/Los_Angeles Europe/Berlin Asia/Tokyo; do
  for f in web/tests/fixtures/week.json web/tests/fixtures/sample-day.json; do
    TZ=$tz "$OUT/places/bin" "$f" > "$OUT/s.txt"; TZ=$tz node web/tests/places_dump.mjs "$f" > "$OUT/j.txt"
    check "places    $(basename "$f") $tz" "$OUT/s.txt" "$OUT/j.txt"
  done
done
F=(web/tests/fixtures/import/*)
"$OUT/imports/bin" "${F[@]}" > "$OUT/s.txt"; node web/tests/import_dump.mjs "${F[@]}" > "$OUT/j.txt"
check "importers (${#F[@]} files)" "$OUT/s.txt" "$OUT/j.txt"

exit $fail
