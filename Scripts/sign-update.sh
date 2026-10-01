#!/usr/bin/env bash
# Package a preview ZIP or sign the final notarized DMG and its appcast.
# --appcast must run AFTER notarize-dmg.sh; signed archives are immutable.
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${MUSES_VERSION:-0.5.9}"
case "${1:-}" in
    "")
        [[ -d build/Muses.app ]] || { echo 'Build Muses.app first.' >&2; exit 1; }
        ditto -c -k --keepParent build/Muses.app "build/Muses-${VER}.zip"
        ;;
    --appcast)
        DMG="build/Muses-${VER}.dmg"
        [[ -f "$DMG" ]] || { echo 'Missing final update DMG.' >&2; exit 1; }
        codesign --verify --deep --strict build/Muses.app
        xcrun stapler validate build/Muses.app
        xcrun stapler validate "$DMG"
        SPARKLE_TOOLS=".build/artifacts/sparkle/Sparkle/bin"
        FEED_DIR="build/update-feed-${VER}"
        mkdir -p "$FEED_DIR"
        cp "$DMG" "$FEED_DIR/"
        SIGN_ARGS=(--account "${MUSES_UPDATE_KEY_ACCOUNT:-muses-polyhymnia}")
        if [[ -n "${MUSES_UPDATE_PRIVATE_KEY_FILE:-}" ]]; then
            SIGN_ARGS=(--ed-key-file "$MUSES_UPDATE_PRIVATE_KEY_FILE")
        fi
        "$SPARKLE_TOOLS/generate_appcast" "${SIGN_ARGS[@]}" \
            --maximum-deltas 0 \
            --download-url-prefix "https://github.com/xiaotwu/Muses-Polyhymnia/releases/download/v${VER}/" \
            --link "https://github.com/xiaotwu/Muses-Polyhymnia/releases/tag/v${VER}" \
            "$FEED_DIR"
        swift Scripts/verify-update-signatures.swift build/Muses.app "$FEED_DIR/appcast.xml" "$DMG"
        python3 Scripts/validate-update-feed.py "$FEED_DIR/appcast.xml" build/Muses.app "$DMG"
        echo "Signed update feed: $FEED_DIR/appcast.xml"
        ;;
    *) echo 'Usage: sign-update.sh [--appcast]' >&2; exit 2 ;;
esac
