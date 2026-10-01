#!/usr/bin/env bash
# Build the approved installer artwork and a fixed native Finder layout.
set -euo pipefail
cd "$(dirname "$0")/.."
VER="${MUSES_VERSION:-0.5.9}"
APP="${MUSES_DMG_APP:-build/Muses.app}"
DMG="${MUSES_DMG_OUTPUT:-build/Muses-${VER}.dmg}"
IDENTITY="${MUSES_SIGN_IDENTITY:--}"
[[ -d "$APP" ]] || { echo "Missing application: $APP" >&2; exit 1; }
[[ ! -e "$DMG" ]] || { echo "Refusing to overwrite an existing DMG: $DMG" >&2; exit 1; }
mkdir -p .build build
TOOLS=".build/dmg-tools"
if [[ ! -x "$TOOLS/bin/python" ]]; then
    python3 -m venv "$TOOLS"
fi
if ! "$TOOLS/bin/python" - <<'VERSIONS'
from importlib.metadata import version
assert version("ds-store") == "1.3.3" and version("mac-alias") == "2.2.3"
VERSIONS
then
    "$TOOLS/bin/python" -m pip install --disable-pip-version-check -r Scripts/requirements-dmg.txt
fi
WORK="$(mktemp -d "$PWD/.build/dmg-layout.XXXXXX")"
MOUNT="$WORK/mount"
MOUNTED=NO
cleanup() {
    if [[ "$MOUNTED" == YES ]]; then hdiutil detach "$MOUNT" >/dev/null || true; fi
}
trap cleanup EXIT
mkdir -p "$WORK/staging/.background" "$MOUNT"
ditto "$APP" "$WORK/staging/Muses.app"
ln -s /Applications "$WORK/staging/Applications"
swift Scripts/render-installer-background.swift \
    Sources/Muses/Resources/IslandMoments-Regular.ttf "$WORK/staging/.background/installer.png"
# An alias must be created on the mounted volume, so it survives relocation.
hdiutil create -volname "Muses · Polyhymnia" -srcfolder "$WORK/staging" \
    -fs APFS -format UDRW "$WORK/layout.dmg"
hdiutil attach "$WORK/layout.dmg" -mountpoint "$MOUNT" -nobrowse -noautoopen
MOUNTED=YES
"$TOOLS/bin/python" Scripts/configure-dmg-layout.py "$MOUNT"
sync
hdiutil detach "$MOUNT"
MOUNTED=NO
hdiutil convert "$WORK/layout.dmg" -format UDBZ -o "$DMG"
if [[ "$IDENTITY" != "-" ]]; then
    codesign --sign "$IDENTITY" "$DMG"
    codesign --verify --strict "$DMG"
fi
"$TOOLS/bin/python" - "$WORK" <<'CLEANUP'
import shutil, sys
shutil.rmtree(sys.argv[1])
CLEANUP
printf 'Created installer: %s\n' "$DMG"
