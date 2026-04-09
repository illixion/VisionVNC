#!/bin/bash
set -euo pipefail

# Build VisionVNC with Moonlight and publish an unsigned IPA as a GitHub Release.
#
# Prerequisites:
#   - gh CLI authenticated
#   - Local deps set up in repos/ (royalvnc, moonlight-common-c, opus)
#   - Xcode with visionOS SDK
#
# Usage:
#   ./scripts/release.sh              # Build and release
#   ./scripts/release.sh --dry-run    # Build only, skip GitHub release

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--dry-run]"
            echo "  --dry-run  Build IPA but skip GitHub release"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

cd "$PROJECT_ROOT"

# Version from git
SHORT_SHA=$(git rev-parse --short=8 HEAD)
VERSION="0.1.0-${SHORT_SHA}"
IPA_NAME="VisionVNC-${VERSION}-unsigned.ipa"

BUILD_DIR="$PROJECT_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/VisionVNC.xcarchive"

# --- Build ---
echo "==> Building archive (Release + Moonlight)..."
xcodebuild archive \
    -project VisionVNC.xcodeproj \
    -scheme VisionVNC \
    -destination 'generic/platform=visionOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) MOONLIGHT_ENABLED'

# --- Package IPA ---
echo "==> Packaging unsigned IPA..."
APP_PATH="$ARCHIVE_PATH/Products/Applications/VisionVNC.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: No .app found in archive" >&2
    exit 1
fi

rm -rf "$BUILD_DIR/Payload"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP_PATH" "$BUILD_DIR/Payload/"
IPA_PATH="$BUILD_DIR/$IPA_NAME"
(cd "$BUILD_DIR" && rm -f "$IPA_NAME" && zip -qr "$IPA_NAME" Payload)
echo "  Built: $IPA_PATH"

if [[ "$DRY_RUN" == true ]]; then
    echo "==> Dry run — skipping GitHub release"
    exit 0
fi

# --- GitHub Release ---
echo "==> Creating GitHub release ($VERSION)..."

# Delete existing "latest" release if present
if gh release view latest &>/dev/null; then
    echo "  Deleting previous 'latest' release..."
    gh release delete latest --yes --cleanup-tag
fi

gh release create latest \
    --title "Latest Release" \
    --notes "Built from \`${SHORT_SHA}\` on $(date +%Y-%m-%d).

This is an unsigned IPA built with Moonlight support (GPLv3). See [LICENSE](LICENSE.txt) for details." \
    --latest \
    "$IPA_PATH#$IPA_NAME"

echo ""
echo "Done! Release published: $(gh release view latest --json url -q .url)"
