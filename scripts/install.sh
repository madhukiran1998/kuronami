#!/bin/sh
# Builds an optimized Release and installs it to /Applications/Kuronami.app.
# Running sessions keep going: the new app restores them on launch.
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Hyperterm.xcodeproj -scheme Hyperterm -configuration Release \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
# Also stops a copy installed under the old name (Hyperterm.app), which shares this app's data.
for PID in $(pgrep -f "/Contents/MacOS/(Kuronami|Hyperterm)$" || true); do kill "$PID"; done
sleep 1.5
rm -rf /Applications/Kuronami.app /Applications/Hyperterm.app
cp -R build/DerivedData/Build/Products/Release/Kuronami.app /Applications/Kuronami.app
open /Applications/Kuronami.app
echo "Installed /Applications/Kuronami.app"
