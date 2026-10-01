#!/usr/bin/env bash
# build-app.sh — 把 SPM release 可执行装配成 Muses.app。
#
# 步骤:copy-ytdlp → make-icon → swift build -c release → 装配 Contents/
# → 拷贝资源 / Info.plist → 注入版本 → codesign(ad-hoc 或 Developer ID)→ 验证。
#
# Sparkle is embedded and signed inside-out. Unconfigured previews do not update.
#
# 参数/环境:
#   --identity <id>   签名身份(默认 $MUSES_SIGN_IDENTITY 或 "-" = ad-hoc)
#   MUSES_VERSION     Override CFBundleShortVersionString (default 0.5.11)
#   MUSES_BUILD       Override CFBundleVersion (default 20261001.5)
#   MUSES_GOOGLE_OAUTH_CLIENT_ID       Muses 项目持有的 Desktop OAuth client ID
#   MUSES_GOOGLE_OAUTH_CLIENT_SECRET   Matching Desktop OAuth field when required by the issuer
#   MUSES_GOOGLE_OAUTH_REDIRECT_URI    可选；默认 http://127.0.0.1:0/（Desktop loopback 随机端口）
#   MUSES_WEB_HOME_ENABLED             构建级 kill switch(默认 YES)
#
# 用法:
#   ./Scripts/build-app.sh                        # ad-hoc dev 构建
#   MUSES_SIGN_IDENTITY="Developer ID Application: ..." ./Scripts/build-app.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# 解析 --identity。
# Use --output to stage validation builds without replacing a running bundle.
IDENTITY="${MUSES_SIGN_IDENTITY:-}"
APP="build/Muses.app"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) IDENTITY="$2"; shift 2 ;;
        --output) APP="$2"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 1 ;;
    esac
done
[[ -z "$IDENTITY" ]] && IDENTITY="-"
if [[ "$APP" != *.app || "$APP" == ".app" ]]; then
    echo "Output must be an .app bundle path" >&2
    exit 1
fi

VERSION="${MUSES_VERSION:-0.5.11}"
BUILD="${MUSES_BUILD:-20261001.5}"

CONTENTS="$APP/Contents"

echo "== Muses .app 打包 (身份: $IDENTITY, 版本: $VERSION) =="

# 1) 前置:yt-dlp + 图标。
./Scripts/copy-ytdlp.sh
./Scripts/make-icon.sh

# 2) Release 构建。
echo "[1/5] swift build -c release"
swift build -c release
RELEASE_DIR="$(swift build -c release --show-bin-path)"

# 3) 装配 .app 结构。
echo "[2/5] 装配 $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Helpers" "$CONTENTS/Frameworks"

cp "$RELEASE_DIR/Muses" "$CONTENTS/MacOS/Muses"
cp "$RELEASE_DIR/MusesWebHomeHelper" "$CONTENTS/Helpers/MusesWebHomeHelper"
chmod 700 "$CONTENTS/Helpers/MusesWebHomeHelper"

# 4) 拷贝资源 + Info.plist。
echo "[3/5] 拷贝 Resources / Info.plist"
RES_DIR="Sources/Muses/Resources"
for f in yt-dlp yt-dlp-LICENSE AppIcon.icns icon.png IslandMoments-Regular.ttf IslandMoments-OFL.txt; do
    [[ -f "$RES_DIR/$f" ]] && cp "$RES_DIR/$f" "$CONTENTS/Resources/"
done
cp "$RES_DIR/Info.plist" "$CONTENTS/Info.plist"
SPARKLE_SOURCE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$SPARKLE_SOURCE" ]]; then
    echo "Missing pinned Sparkle artifact; run swift package resolve" >&2
    exit 1
fi
/usr/bin/ditto "$SPARKLE_SOURCE" "$CONTENTS/Frameworks/Sparkle.framework"
"$REPO_ROOT/Scripts/build-app-intents.sh" Release "$CONTENTS/Resources"
# Bundle.module must resolve inside the installed app, not a source checkout.
RESOURCE_BUNDLE="$RELEASE_DIR/Muses-Polyhymnia_Muses.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    RESOURCE_BUNDLE="$RELEASE_DIR/Muses_Muses.bundle"
fi
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "Missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
    exit 1
fi
/usr/bin/ditto "$RESOURCE_BUNDLE" "$CONTENTS/Resources/Muses_Muses.bundle"
# SwiftPM and Xcode's SwiftPM integration generate different accessor names.
# Both aliases resolve to one copy of the current build's resources.
ln -s Muses_Muses.bundle "$CONTENTS/Resources/Muses-Polyhymnia_Muses.bundle"
# SwiftPM can reuse a resource bundle planned by an earlier test/build before
# copy-ytdlp.sh downloaded the ignored binary. Keep Bundle.module's copy in sync
# with the source that this packaging run just fetched.
BUNDLED_RESOURCES="$CONTENTS/Resources/Muses_Muses.bundle/Contents/Resources/Resources"
mkdir -p "$BUNDLED_RESOURCES"
cp "$RES_DIR/yt-dlp" "$BUNDLED_RESOURCES/yt-dlp"
[[ ! -f "$RES_DIR/yt-dlp-LICENSE" ]] || cp "$RES_DIR/yt-dlp-LICENSE" "$BUNDLED_RESOURCES/yt-dlp-LICENSE"

# Shipping bundles contain only app resources. Catch accidental fixture and
# acceptance-data copies before signing makes the bundle immutable.
if find "$CONTENTS" \( -iname '*fixture*' -o -iname '*acceptance*' -o -iname '*testdata*' \
    -o -iname '*.sqlite' -o -iname '*.sqlite-shm' -o -iname '*.sqlite-wal' \
    -o -iname '*.db' -o -iname '*.log' -o -iname '*.xcresult' \) -print -quit | grep -q .; then
    echo "Release bundle contains test or user data" >&2
    exit 1
fi

# 5) 注入版本号。
echo "[4/5] 注入版本 $VERSION ($BUILD)"
PLIST="/usr/libexec/PlistBuddy"
"$PLIST" -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
"$PLIST" -c "Set :CFBundleVersion $BUILD" "$CONTENTS/Info.plist"
"$PLIST" -c "Set :MusesGoogleOAuthClientID ${MUSES_GOOGLE_OAUTH_CLIENT_ID:-}" "$CONTENTS/Info.plist"
"$PLIST" -c "Set :MusesGoogleOAuthClientSecret ${MUSES_GOOGLE_OAUTH_CLIENT_SECRET:-}" "$CONTENTS/Info.plist"
"$PLIST" -c "Set :MusesGoogleOAuthRedirectURI ${MUSES_GOOGLE_OAUTH_REDIRECT_URI:-http://127.0.0.1:0/}" "$CONTENTS/Info.plist"
"$PLIST" -c "Set :MusesWebHomeEnabled ${MUSES_WEB_HOME_ENABLED:-YES}" "$CONTENTS/Info.plist"

if [[ "${MUSES_AUTOMATIC_UPDATES_REQUIRED:-NO}" == YES && -z "${MUSES_UPDATE_PUBLIC_KEY:-}" ]]; then
    # Read an already provisioned public key; builds never create private keys.
    MUSES_UPDATE_PUBLIC_KEY="$(.build/artifacts/sparkle/Sparkle/bin/generate_keys \
        --account "${MUSES_UPDATE_KEY_ACCOUNT:-muses-polyhymnia}" -p)"
    export MUSES_UPDATE_PUBLIC_KEY
fi
MUSES_SIGN_IDENTITY="$IDENTITY" MUSES_BUNDLE_PATH="$APP" python3 "$REPO_ROOT/Scripts/configure-updates.py"
"$REPO_ROOT/Scripts/sync-app-icon.sh" "$APP"

# 6) Sign every nested executable before signing the app.
echo "[5/5] codesign (--deep --options runtime)"
ENTITLEMENTS="$RES_DIR/Muses.entitlements"
YTDLP_ENTITLEMENTS="$RES_DIR/YTDLP.entitlements"
TIMESTAMP_ARGS=(--timestamp=none)
if [[ "$IDENTITY" != "-" ]]; then
    TIMESTAMP_ARGS=(--timestamp)
fi
# SwiftPM also copies yt-dlp into Bundle.module resources. Apple notarization
# checks both copies independently, including Developer ID, timestamp, and runtime.
for YTDLP_BINARY in \
    "$CONTENTS/Resources/yt-dlp" \
    "$CONTENTS/Resources/Muses_Muses.bundle/Contents/Resources/Resources/yt-dlp"; do
    if [[ ! -f "$YTDLP_BINARY" ]]; then
        echo "Missing bundled yt-dlp: $YTDLP_BINARY" >&2
        exit 1
    fi
    # The standalone yt-dlp is a PyInstaller one-file executable. Its Python
    # library is unpacked at launch and needs this runtime exception.
    codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" \
        --entitlements "$YTDLP_ENTITLEMENTS" \
        --sign "$IDENTITY" "$YTDLP_BINARY"
done
# Sign Sparkle's helpers and XPC services before the enclosing framework.
SPARKLE="$CONTENTS/Frameworks/Sparkle.framework/Versions/B"
for component in "$SPARKLE/XPCServices/Downloader.xpc" "$SPARKLE/XPCServices/Installer.xpc" \
                 "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
    codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" --sign "$IDENTITY" "$component"
done
codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" --sign "$IDENTITY" \
    "$CONTENTS/Frameworks/Sparkle.framework"

# Helper 必须先用与主 app 相同的身份签名；主进程会在每次启动前校验固定路径、
# 严格签名和 TeamIdentifier，绝不从 PATH 加载同名程序。
codesign --force --options runtime "${TIMESTAMP_ARGS[@]}" \
    --sign "$IDENTITY" "$CONTENTS/Helpers/MusesWebHomeHelper"
codesign --deep --force --options runtime "${TIMESTAMP_ARGS[@]}" \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" "$APP"

# 7) 验证。
codesign --verify --deep --strict "$CONTENTS/Frameworks/Sparkle.framework"
otool -L "$CONTENTS/MacOS/Muses" | grep -q '@rpath/Sparkle.framework/'
codesign --verify --deep --strict "$APP" && echo "      ✓ codesign 验证通过"
codesign --verify --strict "$CONTENTS/Helpers/MusesWebHomeHelper" \
    && echo "      ✓ Web Home helper 签名验证通过"
for YTDLP_BINARY in \
    "$CONTENTS/Resources/yt-dlp" \
    "$CONTENTS/Resources/Muses_Muses.bundle/Contents/Resources/Resources/yt-dlp"; do
    "$YTDLP_BINARY" --version >/dev/null
done
echo "      ✓ 两份 yt-dlp 在 hardened runtime 下启动通过"
if [[ "$IDENTITY" != "-" ]]; then
    codesign -dvvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier" || true
fi

echo ""
echo "完成: $APP"
echo "启动: open $APP"
