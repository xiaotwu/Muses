#!/usr/bin/env bash
# Build AppIcon.icns from the canonical app artwork.
#
# 产物:Sources/Muses/Resources/AppIcon.icns(由 Info.plist CFBundleIconFile=AppIcon 引用)。
# 幂等:若 .icns 存在且新于源 png 则跳过。
#
# 用法:./Scripts/make-icon.sh

set -euo pipefail

SOURCE="assets/icon.png"
ICONSET="build/AppIcon.iconset"
PREPARED_SOURCE="build/AppIcon-prepared.png"
DEST="Sources/Muses/Resources/AppIcon.icns"

if [[ ! -f "$SOURCE" ]]; then
    echo "错误:源图标 $SOURCE 不存在" >&2
    exit 1
fi

# Keep in-app branding and the system icon on the same canonical artwork.
for runtime_copy in Sources/Muses/Resources/icon.png docs/assets/icon.png; do
    if ! cmp -s "$SOURCE" "$runtime_copy"; then
        cp "$SOURCE" "$runtime_copy"
    fi
done

# 幂等:产物存在且新于源 → 跳过。
if [[ -f "$DEST" ]] && [[ "$DEST" -nt "$SOURCE" ]] \
   && [[ "$DEST" -nt "$0" ]] \
   && [[ "$DEST" -nt "Scripts/prepare-app-icon.swift" ]]; then
    echo "AppIcon.icns 已是最新,跳过。"
    exit 0
fi

mkdir -p "$ICONSET"
rm -f "$ICONSET"/*.png

# Use the original white-backed artwork without an additional border or shadow.
swift Scripts/prepare-app-icon.swift "$SOURCE" "$PREPARED_SOURCE"

# 生成标准 iconset 尺寸(@1x + @2x)。
sips -z 16 16     "$PREPARED_SOURCE" --out "$ICONSET/icon_16x16.png"        >/dev/null
sips -z 32 32     "$PREPARED_SOURCE" --out "$ICONSET/icon_16x16@2x.png"     >/dev/null
sips -z 32 32     "$PREPARED_SOURCE" --out "$ICONSET/icon_32x32.png"        >/dev/null
sips -z 64 64     "$PREPARED_SOURCE" --out "$ICONSET/icon_32x32@2x.png"     >/dev/null
sips -z 128 128   "$PREPARED_SOURCE" --out "$ICONSET/icon_128x128.png"      >/dev/null
sips -z 256 256   "$PREPARED_SOURCE" --out "$ICONSET/icon_128x128@2x.png"   >/dev/null
sips -z 256 256   "$PREPARED_SOURCE" --out "$ICONSET/icon_256x256.png"      >/dev/null
sips -z 512 512   "$PREPARED_SOURCE" --out "$ICONSET/icon_256x256@2x.png"   >/dev/null
sips -z 512 512   "$PREPARED_SOURCE" --out "$ICONSET/icon_512x512.png"      >/dev/null
# 1024×1024 作为 512@2x(iconutil 不接受 icon_1024x1024.png)。
sips -z 1024 1024 "$PREPARED_SOURCE" --out "$ICONSET/icon_512x512@2x.png"   >/dev/null

mkdir -p "$(dirname "$DEST")"
iconutil -c icns "$ICONSET" -o "$DEST"
echo "生成 $DEST ($(stat -f%z "$DEST") bytes)"
