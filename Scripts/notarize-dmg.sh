#!/usr/bin/env bash
# Notarize and staple the distributable DMG after make-dmg.sh signs it.
set -euo pipefail

cd "$(dirname "$0")/.."
DMG="build/Muses-${MUSES_VERSION:-0.5.4}.dmg"
if [[ ! -f "$DMG" ]]; then
    echo "Missing signed DMG: $DMG" >&2
    exit 1
fi

SUBMIT_ARGS=()
if [[ -n "${MUSES_NOTARY_PROFILE:-}" ]]; then
    SUBMIT_ARGS+=(--keychain-profile "$MUSES_NOTARY_PROFILE")
elif [[ -n "${MUSES_APPLE_ID:-}" && -n "${MUSES_TEAM_ID:-}" && -n "${MUSES_APP_PASSWORD:-}" ]]; then
    SUBMIT_ARGS+=(--apple-id "$MUSES_APPLE_ID" --team-id "$MUSES_TEAM_ID" --password "$MUSES_APP_PASSWORD")
else
    echo "DMG notarization requires notarytool credentials" >&2
    exit 1
fi

SUBMIT_OUT="$(xcrun notarytool submit "$DMG" "${SUBMIT_ARGS[@]}" --wait 2>&1)" || {
    echo "$SUBMIT_OUT" >&2
    exit 1
}
echo "$SUBMIT_OUT"
STATUS_LINE="$(echo "$SUBMIT_OUT" | grep -iE 'status:' | tail -1 || true)"
if ! echo "$STATUS_LINE" | grep -qiE 'Accepted'; then
    echo "DMG notarization was not Accepted: $STATUS_LINE" >&2
    exit 1
fi

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict "$DMG"
echo "Notarized and stapled DMG: $DMG"
