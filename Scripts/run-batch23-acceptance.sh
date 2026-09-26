#!/usr/bin/env bash
# Isolated, non-sandboxed Release for real yt-dlp playback acceptance.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/MusesBatch23.app"
identifier="com.muses.acceptance.batch23"
case "${1:-build}" in
    build)
        if pgrep -f "^$app/Contents/MacOS/Muses" >/dev/null; then
            echo 'Quit only the Batch 23 acceptance instance before rebuilding.' >&2
            exit 1
        fi
        MUSES_GOOGLE_OAUTH_CLIENT_ID= MUSES_GOOGLE_OAUTH_CLIENT_SECRET= \
            MUSES_WEB_HOME_ENABLED=YES ./Scripts/build-app.sh --identity - --output "$app"
        /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $identifier" "$app/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c 'Set :CFBundleName Muses Batch 23' "$app/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$app/Contents/Info.plist"
        codesign --force --options runtime --sign - \
            --entitlements Sources/Muses/Resources/Muses.entitlements "$app"
        codesign --verify --deep --strict "$app"
        dwarfdump --uuid "$app/Contents/MacOS/Muses"
        ;;
    launch)
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$identifier" ]]
        codesign --verify --deep --strict "$app"
        # Reject symlinked ancestors before the app can open its persistent data.
        for base in "$HOME/Library/Application Support" "$HOME/Library/Caches"; do
            for directory in "$base" "$base/MusesAcceptance" "$base/MusesAcceptance/$identifier"; do
                [[ ! -L "$directory" ]] || { echo 'Acceptance data path is a symlink.' >&2; exit 1; }
            done
        done
        /usr/bin/open -n "$app"
        ;;
    *) echo 'Usage: run-batch23-acceptance.sh [build|launch]' >&2; exit 2 ;;
esac
