#!/bin/bash
# sign-update.sh — 发布打包(Phase 14 起:仅产出 zip,供上传到 GitHub Release)
#
# Phase 14 移除了 Sparkle:更新检查改由 `UpdateService` 调用 GitHub Releases API
# (`repos/xiaotwu/noname123/releases/latest`)完成。本脚本不再做 EdDSA 签名 / appcast
# 注入,只把 build/Muses.app 打成 zip,方便 `gh release create` 上传。
#
# 前置:build/Muses.app 已由 build-app.sh 产出。
# 产物:
#   build/Muses-$VER.zip   可上传到 GitHub Release 的更新包
#
# 用法:
#   MUSES_VERSION=0.4.0 ./Scripts/sign-update.sh

set -euo pipefail

VER="${MUSES_VERSION:-0.4.0}"
APP="build/Muses.app"
ZIP="build/Muses-${VER}.zip"

cd "$(dirname "$0")/.."

# ── 1. 前置检查 ──────────────────────────────────────────────
if [[ ! -d "$APP" ]]; then
  echo "✗ 找不到 ${APP};请先 ./Scripts/build-app.sh" >&2
  exit 1
fi

# ── 2. 打 zip ────────────────────────────────────────────────
echo "▶ 打包 ${ZIP} …"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "✓ 完成: ${ZIP}"
echo
echo "═══════════════════════════════════════════════════════"
echo " 发布产物:"
echo "   ${ZIP}   → 上传到 GitHub Release (tag v${VER})"
echo
echo " 上传示例:"
echo "   gh release create v${VER} ${ZIP} \\
        --title \"Muses ${VER}\" --notes \"...\""
echo
echo " 上传后 UpdateService 会自动发现新版本(检查 releases/latest)。"
echo "═══════════════════════════════════════════════════════"