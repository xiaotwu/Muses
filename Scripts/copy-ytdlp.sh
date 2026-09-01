#!/usr/bin/env bash
# copy-ytdlp.sh — 下载 arm64 yt-dlp 二进制到 Muses 资源目录,供打包 .app 时随包分发。
#
# 幂等:已存在且版本相同则跳过。仅个人使用;不分发音频,不上 App Store。
# YouTube 内容受 YouTube ToS 约束,下载行为遵守当地法律。
#
# 用法:
#   ./Scripts/copy-ytdlp.sh            # 下载/更新到 Muses/Sources/Muses/Resources/yt-dlp
#   ./Scripts/copy-ytdlp.sh --check    # 仅打印当前与远端版本,不下载

set -euo pipefail

DEST_DIR="Muses/Sources/Muses/Resources"
DEST="$DEST_DIR/yt-dlp"
REMOTE_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
LICENSE_URL="https://raw.githubusercontent.com/yt-dlp/yt-dlp/master/LICENSE"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

mkdir -p "$DEST_DIR"

current_version() {
    if [[ -x "$DEST" ]]; then
        "$DEST" --version 2>/dev/null || echo "(none)"
    else
        echo "(not installed)"
    fi
}

# 通过 GitHub API 获取最新 release tag(避免下载整个二进制只为查版本)。
remote_version() {
    local response
    response="$(curl -fsSL "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")" \
        || return 1
    # Consume the complete response before parsing. An early-exiting `grep -m1`
    # makes curl receive SIGPIPE under `set -o pipefail`, which used to append
    # `(unknown)` to an otherwise valid tag and redownload the same binary.
    printf '%s\n' "$response" \
        | sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p'
}

echo "== yt-dlp bundling =="
echo "current: $(current_version)"
REMOTE_TAG="$(remote_version || echo '(unknown)')"
echo "remote:  $REMOTE_TAG"

if [[ $CHECK_ONLY -eq 1 ]]; then
    exit 0
fi

# 幂等:已安装版本与远端一致则跳过。
if [[ -x "$DEST" ]] && [[ "$REMOTE_TAG" != "(unknown)" ]]; then
    INSTALLED="$("$DEST" --version 2>/dev/null | head -1 || echo '')"
    if [[ "$INSTALLED" == "$REMOTE_TAG" ]]; then
        echo "已是最新 ($REMOTE_TAG),跳过下载。"
        exit 0
    fi
fi

echo "下载 $REMOTE_URL → $DEST"
curl -fL "$REMOTE_URL" -o "$DEST"
chmod +x "$DEST"

# 附带 LICENSE。
if curl -fsSL "$LICENSE_URL" -o "$DEST_DIR/yt-dlp-LICENSE"; then
    echo "LICENSE → $DEST_DIR/yt-dlp-LICENSE"
fi

echo "完成: $("$DEST" --version | head -1)"
