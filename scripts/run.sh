#!/bin/sh
# Build and (re)launch the debug app.
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Hyperterm.xcodeproj -scheme Hyperterm -configuration "${CONFIG:-Debug}" \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|warning: .*(Hyperterm|Kuronami)|BUILD (SUCCEEDED|FAILED)" | sort -u
APP="$PWD/build/DerivedData/Build/Products/${CONFIG:-Debug}/Kuronami.app"
PID=$(pgrep -f "$APP/Contents/MacOS/Kuronami" || true)
if [ -n "$PID" ]; then kill "$PID"; sleep 1.5; fi
open "$APP"
