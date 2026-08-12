#!/usr/bin/env bash
# make-icon.sh — 从 logo-and-icon/icon.png (1024×1024 RGBA) 生成 AppIcon.icns。
#
# 产物:Muses/Sources/Muses/Resources/AppIcon.icns(由 Info.plist CFBundleIconFile=AppIcon 引用)。
# 幂等:若 .icns 存在且新于源 png 则跳过。
#
# 用法:./Scripts/make-icon.sh

set -euo pipefail

SOURCE="logo-and-icon/icon.png"
ICONSET="build/AppIcon.iconset"
DEST="Muses/Sources/Muses/Resources/AppIcon.icns"

if [[ ! -f "$SOURCE" ]]; then
    echo "错误:源图标 $SOURCE 不存在" >&2
    exit 1
fi

# 幂等:产物存在且新于源 → 跳过。
if [[ -f "$DEST" ]] && [[ "$DEST" -nt "$SOURCE" ]]; then
    echo "AppIcon.icns 已是最新,跳过。"
    exit 0
fi

mkdir -p "$ICONSET"
rm -f "$ICONSET"/*.png

# 生成标准 iconset 尺寸(@1x + @2x)。
sips -z 16 16     "$SOURCE" --out "$ICONSET/icon_16x16.png"        >/dev/null
sips -z 32 32     "$SOURCE" --out "$ICONSET/icon_16x16@2x.png"     >/dev/null
sips -z 32 32     "$SOURCE" --out "$ICONSET/icon_32x32.png"        >/dev/null
sips -z 64 64     "$SOURCE" --out "$ICONSET/icon_32x32@2x.png"     >/dev/null
sips -z 128 128   "$SOURCE" --out "$ICONSET/icon_128x128.png"      >/dev/null
sips -z 256 256   "$SOURCE" --out "$ICONSET/icon_128x128@2x.png"   >/dev/null
sips -z 256 256   "$SOURCE" --out "$ICONSET/icon_256x256.png"      >/dev/null
sips -z 512 512   "$SOURCE" --out "$ICONSET/icon_256x256@2x.png"   >/dev/null
sips -z 512 512   "$SOURCE" --out "$ICONSET/icon_512x512.png"      >/dev/null
# 1024×1024 作为 512@2x(iconutil 不接受 icon_1024x1024.png)。
sips -z 1024 1024 "$SOURCE" --out "$ICONSET/icon_512x512@2x.png"   >/dev/null

mkdir -p "$(dirname "$DEST")"
iconutil -c icns "$ICONSET" -o "$DEST"
echo "生成 $DEST ($(stat -f%z "$DEST") bytes)"