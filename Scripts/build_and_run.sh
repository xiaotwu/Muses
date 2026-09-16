#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Muses"
BUNDLE_ID="com.muses.app"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/build/Muses.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ENTITLEMENTS="$ROOT_DIR/Sources/Muses/Resources/Muses.entitlements"

case "$MODE" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--isolated) ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--isolated]" >&2
        exit 2
        ;;
esac

if [[ "$APP_BUNDLE" != "$ROOT_DIR/build/Muses.app" || -z "$ROOT_DIR" ]]; then
    echo "refusing unexpected app bundle path: $APP_BUNDLE" >&2
    exit 1
fi

if [[ "$MODE" != "--isolated" ]]; then
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

cd "$ROOT_DIR"
"$ROOT_DIR/Scripts/make-icon.sh"
swift build
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"

if [[ ! -x "$BUILD_BINARY" ]]; then
    echo "missing built executable: $BUILD_BINARY" >&2
    exit 1
fi

# Bootstrap the complete resource-bearing bundle only when it does not exist.
# Normal development runs reuse it so UI verification cannot update yt-dlp.
if [[ ! -d "$APP_BUNDLE" || ! -f "$INFO_PLIST" ]]; then
    "$ROOT_DIR/Scripts/build-app.sh"
fi

if [[ ! -d "$APP_CONTENTS/MacOS" || ! -d "$APP_CONTENTS/Resources" || ! -f "$INFO_PLIST" ]]; then
    echo "invalid app bundle structure: $APP_BUNDLE" >&2
    exit 1
fi

# A separate bundle identifier plus the debug-only memory store keeps visual
# validation away from the user's running app, preferences, and persistent store.
if [[ "$MODE" == "--isolated" ]]; then
    ISOLATED_BUNDLE="$ROOT_DIR/build/MusesValidation.app"
    /usr/bin/ditto "$APP_BUNDLE" "$ISOLATED_BUNDLE"
    APP_BUNDLE="$ISOLATED_BUNDLE"
    APP_CONTENTS="$APP_BUNDLE/Contents"
    APP_BINARY="$APP_CONTENTS/MacOS/$APP_NAME"
    INFO_PLIST="$APP_CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.muses.validation" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Muses Validation" "$INFO_PLIST"
fi

cp "$ROOT_DIR/Sources/Muses/Resources/AppIcon.icns" "$APP_CONTENTS/Resources/AppIcon.icns"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
# Keep SwiftPM resources in sync as well as the executable. Reusing a bundle
# with stale localization or artwork produces a misleading development build.
RESOURCE_BUNDLE="$(dirname "$BUILD_BINARY")/Muses_Muses.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    /usr/bin/ditto "$RESOURCE_BUNDLE" "$APP_CONTENTS/Resources/Muses_Muses.bundle"
fi
codesign --deep --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign - "$APP_BUNDLE" >/dev/null
codesign --verify --deep --strict "$APP_BUNDLE"

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    --isolated)
        /usr/bin/open -n --env MUSES_IN_MEMORY_STORE=1 \
            --env "MUSES_VALIDATION_STORE=${MUSES_VALIDATION_STORE:-}" "$APP_BUNDLE"
        ;;
    run)
        open_app
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        open_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        open_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        open_app
        for _ in {1..20}; do
            if pgrep -x "$APP_NAME" >/dev/null; then
                exit 0
            fi
            sleep 0.25
        done
        echo "$APP_NAME did not launch" >&2
        exit 1
        ;;
esac
