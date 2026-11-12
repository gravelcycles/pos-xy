#!/bin/bash
# Builds the Mac viewer and copies it to /Applications. Needs Xcode (not just the CLI tools).
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -project PosXY.xcodeproj -target PosXYViewer -configuration Release \
  SYMROOT="$PWD/build" CODE_SIGN_IDENTITY=- build | grep -E "error|warning: |BUILD" || true

APP="build/Release/PosXYViewer.app"
[ -d "$APP" ] || { echo "Build failed. Open PosXY.xcodeproj in Xcode to see why."; exit 1; }

rm -rf "/Applications/PosXYViewer.app"
cp -R "$APP" /Applications/
echo "Installed /Applications/PosXYViewer.app"
open /Applications/PosXYViewer.app
