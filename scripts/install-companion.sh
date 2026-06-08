#!/bin/bash
set -euo pipefail

# Build the VisionVNC Companion (macOS menu-bar app), install it to
# /Applications, and restart it — quitting the running copy first and
# relaunching the freshly installed one. For a fast local rebuild-test loop:
# TCC permissions (Accessibility, Screen/Audio Recording, Automation) and the
# stored token live with the app in /Applications, not with Xcode's
# DerivedData build, so running the installed copy is what you actually test.
#
# Usage:   scripts/install-companion.sh
#
# Options (env):
#   CONFIG=Debug          build configuration (default: Release)
#   SIGN_IDENTITY="…"     codesign identity (default: "-", ad-hoc). Pass your
#                         Apple Development identity to keep granted TCC
#                         permissions stable across rebuilds.
#
# Note: the companion's bundle id is com.illixion.VisionVNCCompanion. After the
# rename from "Audio Sender" (a different bundle id), macOS treats this as a new
# app — re-grant permissions on first launch and re-pair the token.

SCHEME="VisionVNCCompanion"
APP_NAME="VisionVNCCompanion.app"
EXEC_NAME="VisionVNCCompanion"
BUNDLE_ID="com.illixion.VisionVNCCompanion"
CONFIG="${CONFIG:-Release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" = ad-hoc

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$PROJECT_DIR/build/companion-dd"   # build/ is gitignored
DEST="/Applications/$APP_NAME"

cd "$PROJECT_DIR"

echo "▶ Building $SCHEME ($CONFIG, signing: $SIGN_IDENTITY)…"
xcodebuild \
  -project VisionVNC.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  build

BUILT="$DERIVED/Build/Products/$CONFIG/$APP_NAME"
if [ ! -d "$BUILT" ]; then
  echo "✗ Built app not found at: $BUILT" >&2
  exit 1
fi

echo "▶ Quitting the running app (if any)…"
# Graceful quit of the current build by bundle id; only if it's actually
# running (so AppleScript doesn't launch it just to quit it).
if pgrep -x "$EXEC_NAME" >/dev/null 2>&1; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
fi
# Also clear the pre-rename "Audio Sender" so you don't end up with two
# menu-bar items the first time you run this after the rebrand.
pkill -x "VisionVNCAudioSender" 2>/dev/null || true
# Wait for the menu-bar item / file handles to release, then force-stop if it
# ignored the quit.
for _ in $(seq 1 10); do
  pgrep -x "$EXEC_NAME" >/dev/null 2>&1 || break
  sleep 0.3
done
pkill -x "$EXEC_NAME" 2>/dev/null || true

echo "▶ Installing to ${DEST}…"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"

echo "▶ Launching…"
open "$DEST"

echo "✓ VisionVNC Companion ($CONFIG) installed to /Applications and relaunched."
