#!/bin/bash
# make-dmg.sh — 拖拽安装 DMG(hdiutil + ditto,无 create-dmg 依赖)
#
# 前置:build/Muses.app 已由 build-app.sh(可选 sign-update/notarize)产出。
# 产物:build/Muses-$VER.dmg
#
# 用法:
#   MUSES_VERSION=0.4.0 ./Scripts/make-dmg.sh
#   MUSES_VERSION=0.4.0 MUSES_SIGN_IDENTITY="Developer ID Application: ..." ./Scripts/make-dmg.sh

set -euo pipefail

VER="${MUSES_VERSION:-0.4.0}"
APP="build/Muses.app"
STAGING="build/dmg-staging"
DMG="build/Muses-${VER}.dmg"
IDENTITY="${MUSES_SIGN_IDENTITY:--}"

cd "$(dirname "$0")/.."

if [[ ! -d "$APP" ]]; then
  echo "✗ 找不到 ${APP};请先 ./Scripts/build-app.sh" >&2
  exit 1
fi

# ── 1. 准备 staging(拖拽到 Applications)──────────────────────
echo "▶ 准备 DMG staging …"
rm -rf "$STAGING"
mkdir -p "$STAGING"
# ditto 保留 .app 的符号链接/权限/扩展属性
ditto "$APP" "$STAGING/Muses.app"
ln -sfn /Applications "$STAGING/Applications"

# ── 2. 创建 DMG ───────────────────────────────────────────────
echo "▶ 创建 ${DMG} …"
rm -f "$DMG"
# UDBZ(bzip2)兼容性好;volname 决定挂载后显示的卷名
hdiutil create \
  -volname "Muses" \
  -srcfolder "$STAGING" \
  -fs APFS \
  -format UDBZ \
  "$DMG"

# ── 3. 签名 DMG(正式身份时)──────────────────────────────────
if [[ "$IDENTITY" != "-" ]]; then
  echo "▶ 签名 DMG($IDENTITY)…"
  codesign --sign "$IDENTITY" "$DMG"
  codesign --verify "$DMG" && echo "✓ DMG 签名验证通过"
else
  echo "ℹ ad-hoc 模式:DMG 未签名(本地分发 OK)"
fi

# ── 4. 清理 staging ──────────────────────────────────────────
rm -rf "$STAGING"

echo "✓ DMG 产物: ${DMG}"
echo "  双击挂载 → 拖拽 Muses 到 Applications"