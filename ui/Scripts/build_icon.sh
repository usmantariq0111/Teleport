#!/usr/bin/env bash
# Generates Resources/AppIcon.icns from the Swift renderer.
#
# Output:
#   ui/Resources/AppIcon.icns
#   ui/Resources/AppIcon.png      (1024x1024 master)
#
# Requirements: macOS (sips + iconutil)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RES_DIR="$UI_DIR/Resources"
ICONSET="$(mktemp -d)/AppIcon.iconset"

mkdir -p "$RES_DIR" "$ICONSET"

MASTER="$RES_DIR/AppIcon.png"
echo "▶ Rendering master 1024x1024 icon…"
swift "$SCRIPT_DIR/make_icon.swift" "$MASTER" 1024 >/dev/null

declare -a SIZES=(
  "16    icon_16x16.png"
  "32    icon_16x16@2x.png"
  "32    icon_32x32.png"
  "64    icon_32x32@2x.png"
  "128   icon_128x128.png"
  "256   icon_128x128@2x.png"
  "256   icon_256x256.png"
  "512   icon_256x256@2x.png"
  "512   icon_512x512.png"
  "1024  icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
  size="${entry%% *}"
  name="${entry##* }"
  echo "  • $name ($size px)"
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/$name" >/dev/null
done

echo "▶ Packing AppIcon.icns…"
iconutil --convert icns "$ICONSET" --output "$RES_DIR/AppIcon.icns"

rm -rf "$(dirname "$ICONSET")"
echo "✅ Wrote $RES_DIR/AppIcon.icns"
