#!/bin/sh
# Renders the app icon, favicon and Sumi button's layers from the SVGs in docs/brand.
# Needs Google Chrome (headless) for SVG rendering; sips and iconutil ship with macOS.
set -e
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

render() { # svg, size, png
  printf '<!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:transparent}svg{display:block;width:%spx;height:%spx}</style>' "$2" "$2" > "$TMP/page.html"
  cat "$1" >> "$TMP/page.html"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
    --window-size="$2,$2" --screenshot="$3" "file://$TMP/page.html" 2>/dev/null
}

render docs/brand/tako-icon.svg 1024 "$TMP/icon.png"
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
sips -z 256 256 "$TMP/icon.png" --out docs/icon.png >/dev/null

# Sumi button stacks these so the sun can rise and set behind Tako.
for layer in ground sun tako; do render "docs/brand/mark-$layer.svg" 192 "Resources/Mark/$layer.png"; done
echo "Rendered Resources/AppIcon.icns, docs/icon.png and Resources/Mark/{ground,sun,tako}.png"
