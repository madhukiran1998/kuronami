#!/bin/sh
# Builds an optimized Release and installs it to /Applications/Kuronami.app.
# Running sessions keep going: the new app restores them on launch.
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Hyperterm.xcodeproj -scheme Hyperterm -configuration Release \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
# Also stops a copy installed under the old name (Hyperterm.app), which shares this app's data.
PIDS=$(pgrep -f "/Contents/MacOS/(Kuronami|Hyperterm)$" || true)
for PID in $PIDS; do kill "$PID"; done
# Wait for them to really exit (Chromium makes shutdown take a few seconds): a new copy that
# finds the old one still answering its socket hands off to it and quits.
for _ in $(seq 1 40); do
  STILL=""
  for PID in $PIDS; do kill -0 "$PID" 2>/dev/null && STILL=1; done
  [ -z "$STILL" ] && break
  sleep 0.25
done
rm -rf /Applications/Kuronami.app /Applications/Hyperterm.app
cp -R build/DerivedData/Build/Products/Release/Kuronami.app /Applications/Kuronami.app
open /Applications/Kuronami.app
echo "Installed /Applications/Kuronami.app"
