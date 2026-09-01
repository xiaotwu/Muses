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
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac

if [[ "$APP_BUNDLE" != "$ROOT_DIR/build/Muses.app" || -z "$ROOT_DIR" ]]; then
    echo "refusing unexpected app bundle path: $APP_BUNDLE" >&2
    exit 1
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
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

cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
codesign --deep --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign - "$APP_BUNDLE" >/dev/null
codesign --verify --deep --strict "$APP_BUNDLE"

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
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
