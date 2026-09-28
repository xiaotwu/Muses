#!/usr/bin/env bash
# Install canonical artwork and the modern named system icon together.
set -euo pipefail

APP="${1:?Usage: sync-app-icon.sh /path/to/Muses.app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="$APP/Contents/Resources"
PLIST="$APP/Contents/Info.plist"
SOURCE="$ROOT/Sources/Muses/Resources"
[[ -f "$PLIST" && -d "$RESOURCES" ]] || { echo "Invalid app bundle" >&2; exit 1; }

# Modern macOS surfaces render the named Icon Composer asset; ICNS alone can
# receive a synthesized inset tile even when its pixels are correct.
ICON_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/muses-icon.XXXXXX")"
trap 'rm -rf "$ICON_BUILD"' EXIT
ditto "$ROOT/assets/Muses.icon" "$ICON_BUILD/Muses.icon"
cp "$ROOT/assets/icon.png" "$ICON_BUILD/Muses.icon/Assets/icon.png"
mkdir "$ICON_BUILD/output"
xcrun actool "$ICON_BUILD/Muses.icon" \
    --compile "$ICON_BUILD/output" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon Muses \
    --output-partial-info-plist "$ICON_BUILD/info.plist" >/dev/null
cp "$ICON_BUILD/output/Assets.car" "$RESOURCES/Assets.car"
cp "$ICON_BUILD/output/Muses.icns" "$RESOURCES/Muses.icns"
/usr/bin/plutil -replace CFBundleIconName -string Muses "$PLIST"

cp "$SOURCE/icon.png" "$RESOURCES/icon.png"
cp "$SOURCE/AppIcon.icns" "$RESOURCES/AppIcon.icns"
MODULE_RESOURCES="$RESOURCES/Muses_Muses.bundle/Contents/Resources/Resources"
if [[ -d "$MODULE_RESOURCES" ]]; then
    cp "$SOURCE/icon.png" "$MODULE_RESOURCES/icon.png"
    cp "$SOURCE/AppIcon.icns" "$MODULE_RESOURCES/AppIcon.icns"
fi
/usr/bin/plutil -replace CFBundleIconFile -string Muses "$PLIST"
# Call before signing. Installation should also register the resulting app.
touch "$APP"
