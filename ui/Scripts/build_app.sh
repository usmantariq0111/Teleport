#!/usr/bin/env bash
# Builds Teleport.app — a fully self-contained .app bundle:
#
#   ui/Teleport.app/
#     Contents/
#       Info.plist
#       MacOS/TeleportUI            (Swift binary)
#       MacOS/teleport-daemon       (Rust binary, optional)
#       Resources/AppIcon.icns
#
# Flags:
#   --release   build Swift (and daemon) in release mode
#   --no-daemon skip bundling the Rust daemon binary
#   --sign IDENTITY   codesign with the given identity (optional)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$UI_DIR/.." && pwd)"
DAEMON_DIR="$ROOT_DIR/daemon"
APP_DIR="$UI_DIR/Teleport.app"
RES_DIR="$UI_DIR/Resources"

CONFIG="debug"
SWIFT_FLAGS=()
CARGO_FLAGS=()
BUNDLE_DAEMON=1
SIGN_IDENTITY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      CONFIG="release"
      SWIFT_FLAGS+=("-c" "release")
      CARGO_FLAGS+=("--release")
      shift ;;
    --no-daemon)
      BUNDLE_DAEMON=0
      shift ;;
    --sign)
      SIGN_IDENTITY="$2"
      shift 2 ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2 ;;
  esac
done

echo "▶ Building Teleport.app ($CONFIG)"

# ---- 1. Icon ----
if [[ ! -f "$RES_DIR/AppIcon.icns" ]]; then
  echo "▶ Generating AppIcon.icns…"
  "$SCRIPT_DIR/build_icon.sh"
fi

# ---- 2. Swift binary ----
echo "▶ Compiling Swift UI…"
( cd "$UI_DIR" && swift build ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} )
SWIFT_BIN="$UI_DIR/.build/$CONFIG/TeleportUI"
if [[ ! -x "$SWIFT_BIN" ]]; then
  echo "Swift binary not found at $SWIFT_BIN" >&2
  exit 1
fi

# ---- 3. (Optional) Rust daemon ----
DAEMON_BIN=""
if [[ $BUNDLE_DAEMON -eq 1 ]]; then
  if [[ -d "$DAEMON_DIR" ]]; then
    echo "▶ Compiling Rust daemon…"
    ( cd "$DAEMON_DIR" && cargo build ${CARGO_FLAGS[@]+"${CARGO_FLAGS[@]}"} )
    DAEMON_BIN="$DAEMON_DIR/target/$CONFIG/teleport-daemon"
    if [[ ! -x "$DAEMON_BIN" ]]; then
      echo "⚠️  Daemon binary not found at $DAEMON_BIN — skipping bundling."
      DAEMON_BIN=""
    fi
  fi
fi

# ---- 4. Assemble bundle ----
echo "▶ Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$RES_DIR/Info.plist"   "$APP_DIR/Contents/Info.plist"
cp "$RES_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$SWIFT_BIN"            "$APP_DIR/Contents/MacOS/TeleportUI"
chmod +x "$APP_DIR/Contents/MacOS/TeleportUI"

if [[ -n "$DAEMON_BIN" ]]; then
  cp "$DAEMON_BIN" "$APP_DIR/Contents/MacOS/teleport-daemon"
  chmod +x "$APP_DIR/Contents/MacOS/teleport-daemon"
  echo "  • Bundled teleport-daemon"
fi

# ---- 5. Codesign (optional) ----
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "▶ Codesigning with: $SIGN_IDENTITY"
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR"
else
  # Ad-hoc sign so macOS doesn't kill the app from quarantine on local runs.
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

# ---- 6. Refresh icon cache so Finder shows the new icon ----
touch "$APP_DIR"

echo "✅ Built $APP_DIR"
echo "   Run with: open '$APP_DIR'"
