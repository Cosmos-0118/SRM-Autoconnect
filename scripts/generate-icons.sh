#!/bin/bash
# Renders Assets/AppIcon.svg into every size macOS needs and packs them into
# Assets/AppIcon.icns. Run this whenever the source SVG changes; build.sh just
# copies the resulting .icns into the app bundle.
set -e

cd "$(dirname "$0")/.."

SRC_SVG="Assets/AppIcon.svg"
ICONSET="Assets/AppIcon.iconset"
OUT_ICNS="Assets/AppIcon.icns"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "rsvg-convert not found. Install it with: brew install librsvg" >&2
  exit 1
fi

if [ ! -f "$SRC_SVG" ]; then
  echo "Source icon not found at $SRC_SVG" >&2
  exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

render() {
  local px="$1" name="$2"
  rsvg-convert -w "$px" -h "$px" "$SRC_SVG" -o "$ICONSET/$name"
}

render 16   icon_16x16.png
render 32   icon_16x16@2x.png
render 32   icon_32x32.png
render 64   icon_32x32@2x.png
render 128  icon_128x128.png
render 256  icon_128x128@2x.png
render 256  icon_256x256.png
render 512  icon_256x256@2x.png
render 512  icon_512x512.png
render 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
rm -rf "$ICONSET"

echo "Icon generated: $OUT_ICNS"
