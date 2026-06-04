#!/bin/bash
set -euo pipefail

# Set up the local SPM dependencies in repos/ (gitignored), recreating the
# CI dependency steps so a full Moonlight-enabled build works locally.
# CI itself builds with Moonlight DISABLED (enet doesn't compile on the
# runner image) — this script is the local path to a complete build.
#
# Idempotent: existing checkouts are left untouched. Use --force to wipe
# repos/ and re-clone everything.
#
# Usage:
#   ./scripts/setup-deps.sh            # clone + patch anything missing
#   ./scripts/setup-deps.sh --force    # wipe repos/ and redo from scratch

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Pinned dependency versions (keep in sync with the historical CI pins)
ROYALVNC_REF='337197a'
MOONLIGHT_COMMON_C_REF='7b026e77be62175104640e7e722b758df6d3d0d7'
OPUS_REF='788cc89ce4f2c42025d8c70ec1b4457dc89cd50f'

cd "$PROJECT_ROOT"

if [[ "${1:-}" == "--force" ]]; then
    echo "==> Removing repos/ for a clean re-setup"
    rm -rf repos
fi
mkdir -p repos

if [[ -d repos/royalvnc ]]; then
    echo "==> repos/royalvnc exists — skipping (use --force to redo)"
else
    echo "==> Cloning and patching RoyalVNC ($ROYALVNC_REF)"
    git clone https://github.com/royalapplications/royalvnc.git repos/royalvnc
    (
        cd repos/royalvnc
        git checkout "$ROYALVNC_REF"
        # Use static linking to avoid dyld embedding issues on visionOS
        sed -i '' 's/type: .dynamic/type: .static/' Package.swift
    )
fi

if [[ -d repos/moonlight-common-c ]]; then
    echo "==> repos/moonlight-common-c exists — skipping (use --force to redo)"
else
    echo "==> Cloning and patching moonlight-common-c ($MOONLIGHT_COMMON_C_REF)"
    git clone --recursive https://github.com/moonlight-stream/moonlight-common-c.git repos/moonlight-common-c
    (
        cd repos/moonlight-common-c
        git checkout "$MOONLIGHT_COMMON_C_REF"
        # Add SPM Package.swift wrapper and public headers directory
        cp ../../ci/deps/moonlight-common-c/Package.swift .
        mkdir -p include
        cp src/Limelight.h include/
        # Apply FEC recovery crash fixes for newer Sunshine versions
        git apply ../../ci/patches/moonlight-common-c-fec-fix.patch
        git apply ../../ci/patches/moonlight-common-c-audio-fec-fix.patch
        # Add CommonCrypto backend for AES-GCM/CBC (replaces OpenSSL on Apple platforms)
        git apply ../../ci/patches/moonlight-common-c-commoncrypto.patch
    )
fi

if [[ -d repos/opus ]]; then
    echo "==> repos/opus exists — skipping (use --force to redo)"
else
    echo "==> Cloning and patching Opus ($OPUS_REF)"
    git clone https://github.com/xiph/opus.git repos/opus
    (
        cd repos/opus
        git checkout "$OPUS_REF"
        # Add SPM Package.swift wrapper and config files
        cp ../../ci/deps/opus/Package.swift .
        mkdir -p spm-config
        cp ../../ci/deps/opus/spm-config/config.h spm-config/
        cp ../../ci/deps/opus/include/module.modulemap include/
        # Patch opus.h to include multistream API for SPM umbrella header
        git apply ../../ci/patches/opus-spm-umbrella.patch
    )
fi

echo ""
echo "Done. Build with Moonlight via:"
echo "  ./scripts/build-and-sign.sh   (PRE_BUILD_HOOK runs this script automatically)"
