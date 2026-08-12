#!/usr/bin/env bash
# build-app.sh — 把 SPM release 可执行装配成 Muses.app。
#
# 步骤:copy-ytdlp → make-icon → swift build -c release → 装配 Contents/
# → 嵌入 Sparkle.framework → install_name_tool 加 rpath → 注入 Info.plist 版本
# → codesign(ad-hoc 或 Developer ID)→ 验证。
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
SPARKLE_FW_SOURCE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

echo "== Muses .app 打包 (身份: $IDENTITY, 版本: $VERSION) =="

# 1) 前置:yt-dlp + 图标。
./Scripts/copy-ytdlp.sh
./Scripts/make-icon.sh

# 2) Release 构建。
echo "[1/6] swift build -c release"
swift build -c release

if [[ ! -d "$SPARKLE_FW_SOURCE" ]]; then
    echo "错误:Sparkle.framework 不在 $SPARKLE_FW_SOURCE" >&2
    echo "(SPM 应在 resolve 时下载;尝试 swift package resolve)" >&2
    exit 1
fi

# 3) 装配 .app 结构。
echo "[2/6] 装配 $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

cp ".build/release/Muses" "$CONTENTS/MacOS/Muses"

# 4) 嵌入 Sparkle.framework(ditto 保留符号链接)。
echo "[3/6] 嵌入 Sparkle.framework"
ditto "$SPARKLE_FW_SOURCE" "$CONTENTS/Frameworks/Sparkle.framework"

# 5) rpath 修复:让可执行在 .app 内找到 ../Frameworks。
EXE="$CONTENTS/MacOS/Muses"
if ! otool -l "$EXE" | grep -q "LC_RPATH" || ! otool -l "$EXE" | grep -A2 "LC_RPATH" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"
    echo "      已加 rpath @executable_path/../Frameworks"
else
    echo "      rpath 已存在,跳过"
fi

# 6) 拷贝资源 + Info.plist + entitlements。
echo "[4/6] 拷贝 Resources / Info.plist"
RES_DIR="Muses/Sources/Muses/Resources"
for f in appcast.xml yt-dlp yt-dlp-LICENSE AppIcon.icns; do
    [[ -f "$RES_DIR/$f" ]] && cp "$RES_DIR/$f" "$CONTENTS/Resources/"
done
cp "$RES_DIR/Info.plist" "$CONTENTS/Info.plist"

# 7) 注入版本 + dev 模式清空 SUFeedURL(避免 Sparkle misconfigured 弹窗)。
PLIST="/usr/libexec/PlistBuddy"
"$PLIST" -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
"$PLIST" -c "Set :CFBundleVersion $BUILD" "$CONTENTS/Info.plist"
if [[ "$IDENTITY" == "-" ]]; then
    # dev 构建:禁用 Sparkle 自动更新检查,避免占位 feed 报错。
    "$PLIST" -c "Set :SUFeedURL " "$CONTENTS/Info.plist" 2>/dev/null || true
    "$PLIST" -c "Set :SUEnableAutomaticUpdates false" "$CONTENTS/Info.plist" 2>/dev/null || true
    echo "      dev 模式:已清空 SUFeedURL,Sparkle no-op"
fi

# 8) 签名(entitlements 用源文件;--deep 覆盖 framework + yt-dlp)。
echo "[5/6] codesign (--deep --options runtime)"
ENTITLEMENTS="$RES_DIR/Muses.entitlements"
# yt-dlp 是第三方二进制,先单独 ad-hoc 签名避免 --deep 失败。
if [[ -f "$CONTENTS/Resources/yt-dlp" ]] && ! codesign --verify "$CONTENTS/Resources/yt-dlp" 2>/dev/null; then
    codesign --force --sign - "$CONTENTS/Resources/yt-dlp" 2>/dev/null || true
fi
codesign --deep --force --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"

# 9) 验证。
echo "[6/6] 验证"
codesign --verify --deep --strict "$APP" && echo "      ✓ codesign 验证通过"
if [[ "$IDENTITY" != "-" ]]; then
    codesign -dvvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier" || true
fi

echo ""
echo "完成: $APP"
echo "启动: open $APP"