#!/usr/bin/env bash
# build-app.sh — 把 SPM release 可执行装配成 Muses.app。
#
# 步骤:copy-ytdlp → make-icon → swift build -c release → 装配 Contents/
# → 拷贝资源 / Info.plist → 注入版本 → codesign(ad-hoc 或 Developer ID)→ 验证。
#
# (Phase 14 起:移除 Sparkle.framework 嵌入与 rpath;更新改用 GitHub Releases API
#  检查,见 `Services/Update/UpdateService.swift`。)
#
# 参数/环境:
#   --identity <id>   签名身份(默认 $MUSES_SIGN_IDENTITY 或 "-" = ad-hoc)
#   MUSES_VERSION     覆盖 CFBundleShortVersionString(默认 0.4.0)
#   MUSES_BUILD       覆盖 CFBundleVersion(默认 1)
#
# 用法:
#   ./Scripts/build-app.sh                        # ad-hoc dev 构建
#   MUSES_SIGN_IDENTITY="Developer ID Application: ..." ./Scripts/build-app.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# 解析 --identity。
IDENTITY="${MUSES_SIGN_IDENTITY:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) IDENTITY="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done
[[ -z "$IDENTITY" ]] && IDENTITY="-"

VERSION="${MUSES_VERSION:-0.4.0}"
BUILD="${MUSES_BUILD:-1}"

APP="build/Muses.app"
CONTENTS="$APP/Contents"

echo "== Muses .app 打包 (身份: $IDENTITY, 版本: $VERSION) =="

# 1) 前置:yt-dlp + 图标。
./Scripts/copy-ytdlp.sh
./Scripts/make-icon.sh

# 2) Release 构建。
echo "[1/5] swift build -c release"
swift build -c release

# 3) 装配 .app 结构。
echo "[2/5] 装配 $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp ".build/release/Muses" "$CONTENTS/MacOS/Muses"

# 4) 拷贝资源 + Info.plist。
echo "[3/5] 拷贝 Resources / Info.plist"
RES_DIR="Muses/Sources/Muses/Resources"
for f in yt-dlp yt-dlp-LICENSE AppIcon.icns logo.png MonteCarlo.ttf; do
    [[ -f "$RES_DIR/$f" ]] && cp "$RES_DIR/$f" "$CONTENTS/Resources/"
done
cp "$RES_DIR/Info.plist" "$CONTENTS/Info.plist"

# 5) 注入版本号。
echo "[4/5] 注入版本 $VERSION ($BUILD)"
PLIST="/usr/libexec/PlistBuddy"
"$PLIST" -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
"$PLIST" -c "Set :CFBundleVersion $BUILD" "$CONTENTS/Info.plist"

# 6) 签名(entitlements 用源文件;--deep 覆盖 yt-dlp)。
echo "[5/5] codesign (--deep --options runtime)"
ENTITLEMENTS="$RES_DIR/Muses.entitlements"
# yt-dlp 是第三方二进制,先单独 ad-hoc 签名避免 --deep 失败。
if [[ -f "$CONTENTS/Resources/yt-dlp" ]] && ! codesign --verify "$CONTENTS/Resources/yt-dlp" 2>/dev/null; then
    codesign --force --sign - "$CONTENTS/Resources/yt-dlp" 2>/dev/null || true
fi
codesign --deep --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"

# 7) 验证。
codesign --verify --deep --strict "$APP" && echo "      ✓ codesign 验证通过"
if [[ "$IDENTITY" != "-" ]]; then
    codesign -dvvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier" || true
fi

echo ""
echo "完成: $APP"
echo "启动: open $APP"