#!/bin/sh
# Builds an optimized Release and installs it to /Applications/Kuronami.app.
# Running sessions keep going: the new app restores them on launch.
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Hyperterm.xcodeproj -scheme Hyperterm -configuration Release \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
# macOS's App Management protection can stop this terminal from replacing an app in
# /Applications. Check before quitting anything, so a refused copy never leaves you with no app.
if [ -e /Applications/Kuronami.app ] && ! chmod u+w /Applications/Kuronami.app/Contents 2>/dev/null; then
  echo "macOS won't let this terminal replace /Applications/Kuronami.app."
  echo "Allow it in System Settings > Privacy & Security > App Management (turn on your terminal app),"
  echo "then run scripts/install.sh again. Kuronami was left running."
  exit 1
fi
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
if cp -R build/DerivedData/Build/Products/Release/Kuronami.app /Applications/Kuronami.app 2>/dev/null; then
  open /Applications/Kuronami.app
  echo "Installed /Applications/Kuronami.app"
else
  # The old app is already gone; run the new build from where it was built rather than nothing.
  open build/DerivedData/Build/Products/Release/Kuronami.app
  echo "Couldn't copy into /Applications; opened the new build from build/ instead."
fi
