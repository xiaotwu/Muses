#!/usr/bin/env bash
# Wrap an existing disposable Release bundle; never launch or alter production.
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/MusesAcceptanceSep22.app"
plist="$app/Contents/Info.plist"
if pgrep -f "^$PWD/$app/Contents/MacOS/Muses" >/dev/null; then
    echo 'Quit this acceptance instance before changing its signature.' >&2
    exit 1
fi
entitlements="Scripts/acceptance-sandbox.entitlements"
case "${1:-online}" in
    online) ;;
    offline) entitlements="Scripts/acceptance-offline.entitlements" ;;
    *) echo 'Usage: prepare-acceptance-sandbox.sh [online|offline]' >&2; exit 2 ;;
esac
[[ -f "$plist" ]] || { echo 'Build the acceptance bundle first.' >&2; exit 1; }
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.muses.acceptance.sep22' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Muses Acceptance' "$plist"
# Do not register production deep links or include OAuth client configuration.
/usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Set :MusesGoogleOAuthClientID ' "$plist"
/usr/libexec/PlistBuddy -c 'Set :MusesGoogleOAuthClientSecret ' "$plist"
/usr/libexec/PlistBuddy -c 'Set :MusesWebHomeEnabled NO' "$plist"
codesign --force --options runtime --sign - \
    --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
codesign -d --entitlements :- "$app"
dwarfdump --uuid "$app/Contents/MacOS/Muses"
