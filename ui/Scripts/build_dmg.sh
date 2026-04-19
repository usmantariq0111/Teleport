#!/usr/bin/env bash
# Builds a distributable Teleport.dmg from the .app bundle.
#
#   • Drag-to-/Applications layout (with a symlink shortcut)
#   • Compressed UDZO (zlib) image
#   • Optional --sign IDENTITY  → codesign the .app + DMG before packing
#
# Usage:
#   ./Scripts/build_dmg.sh                 # debug
#   ./Scripts/build_dmg.sh --release
#   ./Scripts/build_dmg.sh --release --sign "Developer ID Application: Your Name (TEAMID)"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$UI_DIR/.." && pwd)"
APP_PATH="$UI_DIR/Teleport.app"
DIST_DIR="$ROOT_DIR/dist"
VOL_NAME="Teleport"

BUILD_FLAGS=()
SIGN_IDENTITY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release|--no-daemon)
      BUILD_FLAGS+=("$1"); shift ;;
    --sign)
      SIGN_IDENTITY="$2"
      BUILD_FLAGS+=("--sign" "$SIGN_IDENTITY")
      shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

# 1. Ensure we have a fresh .app bundle.
echo "▶ Building Teleport.app…"
"$SCRIPT_DIR/build_app.sh" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}

# 2. Determine version for the dmg filename.
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"

mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/Teleport-${VERSION}.dmg"
rm -f "$DMG_PATH"

# 3. Build a staging directory containing the .app and an /Applications alias.
STAGING="$(mktemp -d)/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/Teleport.app"
ln -s /Applications "$STAGING/Applications"

# Touch + clear xattrs so Finder doesn't complain on first open.
xattr -cr "$STAGING/Teleport.app" || true

# 4. Calculate disk size with ~20% slack.
SIZE_KB=$(du -sk "$STAGING" | cut -f1)
SIZE_KB=$(( SIZE_KB + SIZE_KB / 5 + 4096 ))

# 5. Build a writable image, mount it, customize, then convert to compressed read-only.
TMP_DMG="$(mktemp -u).dmg"
echo "▶ Creating $DMG_PATH (volume '$VOL_NAME', $((SIZE_KB / 1024)) MB)"

hdiutil create -srcfolder "$STAGING" \
  -volname "$VOL_NAME" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -size "${SIZE_KB}k" \
  "$TMP_DMG" >/dev/null

MOUNT_DIR="$(mktemp -d)/mnt"
mkdir -p "$MOUNT_DIR"
hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$MOUNT_DIR" "$TMP_DMG" >/dev/null

# Make sure window-state stuff is flushed before unmount.
sync
sleep 1

hdiutil detach "$MOUNT_DIR" >/dev/null

# Compress to read-only UDZO.
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -f "$TMP_DMG"
rm -rf "$STAGING" "$(dirname "$MOUNT_DIR")"

# 6. Optional: codesign the dmg itself.
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "▶ Codesigning DMG with: $SIGN_IDENTITY"
  codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

echo "✅ Wrote $DMG_PATH"
echo "   Size: $(du -h "$DMG_PATH" | cut -f1)"
