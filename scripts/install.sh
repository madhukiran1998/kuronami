#!/bin/sh
# Builds an optimized Release and installs it to /Applications/Hyperterm.app.
# Running sessions keep going: the new app restores them on launch.
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Hyperterm.xcodeproj -scheme Hyperterm -configuration Release \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
for PID in $(pgrep -f "Hyperterm.app/Contents/MacOS/Hyperterm" || true); do kill "$PID"; done
sleep 1.5
rm -rf /Applications/Hyperterm.app
cp -R build/DerivedData/Build/Products/Release/Hyperterm.app /Applications/Hyperterm.app
open /Applications/Hyperterm.app
echo "Installed /Applications/Hyperterm.app"
