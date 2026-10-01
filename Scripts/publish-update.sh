#!/usr/bin/env bash
# Explicit publication: immutable version assets precede switching the stable feed.
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${MUSES_VERSION:?Set MUSES_VERSION}"
REPO="xiaotwu/Muses-Polyhymnia"
DMG="build/Muses-${VER}.dmg"
FEED="build/update-feed-${VER}/appcast.xml"
[[ -f "$DMG" && -f "$FEED" ]] || { echo 'Run make release first.' >&2; exit 1; }
python3 Scripts/validate-update-feed.py "$FEED" build/Muses.app "$DMG"
codesign --verify --deep --strict build/Muses.app
xcrun stapler validate build/Muses.app
xcrun stapler validate "$DMG"
swift Scripts/verify-update-signatures.swift build/Muses.app "$FEED" "$DMG"
# Draft retries are safe; published version assets remain immutable.
if gh release view "v${VER}" --repo "$REPO" >/dev/null 2>&1; then
    [[ "$(gh release view "v${VER}" --repo "$REPO" --json isDraft --jq .isDraft)" == true ]] || {
        echo 'This version is already published; use a new version.' >&2
        exit 1
    }
else
    gh release create "v${VER}" --repo "$REPO" --title "Muses ${VER}" --generate-notes --draft
fi
gh release upload "v${VER}" "$DMG" --repo "$REPO" --clobber
gh release edit "v${VER}" --repo "$REPO" --draft=false
# A failure below leaves a valid version available for manual installation.

if ! gh release view updates --repo "$REPO" >/dev/null 2>&1; then
    gh release create updates --repo "$REPO" --title "Muses update feed" --notes "Signed stable update feed." --prerelease
fi
gh release upload updates "$FEED" --repo "$REPO" --clobber
echo "Published v${VER} and switched the stable update feed."
