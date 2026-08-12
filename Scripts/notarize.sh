#!/bin/bash
# notarize.sh — Apple 公证 + Stapler
#
# 前置:build/Muses-$VER.zip 已由 sign-update.sh 产出。
# 凭据(三选一):
#   (A) MUSES_NOTARY_PROFILE        keychain notarytool profile(推荐)
#   (B) MUSES_APPLE_ID + MUSES_TEAM_ID + MUSES_APP_PASSWORD   Apple ID 凭据
#   (C) 以上都缺                   → 跳过公证(exit 0),不阻塞 dev/CI
#
# 用法:
#   MUSES_VERSION=0.4.0 MUSES_NOTARY_PROFILE=muses ./Scripts/notarize.sh
#
# 产物:
#   build/Muses.app          公证 + staple 后的 .app(staple 改变了文件,需重新 zip)
#   build/Muses-$VER.zip     重新打包的 staple 版 zip(供上传)

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
if [[ ! -f "$ZIP" ]]; then
  echo "ℹ ${ZIP} 不存在,先打 zip 供 notarytool 提交"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

# ── 2. 凭据解析 ───────────────────────────────────────────────
SUBMIT_ARGS=()
if [[ -n "${MUSES_NOTARY_PROFILE:-}" ]]; then
  SUBMIT_ARGS+=(--keychain-profile "$MUSES_NOTARY_PROFILE")
elif [[ -n "${MUSES_APPLE_ID:-}" && -n "${MUSES_TEAM_ID:-}" && -n "${MUSES_APP_PASSWORD:-}" ]]; then
  SUBMIT_ARGS+=(--apple-id "$MUSES_APPLE_ID" --team-id "$MUSES_TEAM_ID" --password "$MUSES_APP_PASSWORD")
else
  echo "═══════════════════════════════════════════════════════"
  echo " ℹ 跳过公证:未配置 Apple 凭据"
  echo "   正式发布请设置以下之一:"
  echo "     (A) MUSES_NOTARY_PROFILE=<keychain profile>"
  echo "         先运行:xcrun notarytool store-credentials muses \\"
  echo "           --apple-id you@example.com --team-id XXXXXXXX \\"
  echo "           --password app-specific-password"
  echo "     (B) MUSES_APPLE_ID + MUSES_TEAM_ID + MUSES_APP_PASSWORD"
  echo "   .app 已签名(本地产物),可直接本地跑或上传。"
  echo "═══════════════════════════════════════════════════════"
  exit 0
fi

# ── 3. 提交公证(--wait 阻塞到完成)────────────────────────────
echo "▶ 提交公证 ${ZIP} …"
SUBMIT_OUT="$(xcrun notarytool submit "$ZIP" "${SUBMIT_ARGS[@]}" --wait 2>&1)" || {
  echo "✗ notarytool submit 失败:" >&2
  echo "$SUBMIT_OUT" >&2
  # 提取 submission id 打日志
  SUB_ID="$(echo "$SUBMIT_OUT" | grep -oE '[0-9a-f-]{36}' | head -1 || true)"
  if [[ -n "$SUB_ID" ]]; then
    echo "→ 查看日志:xcrun notarytool log $SUB_ID ${SUBMIT_ARGS[*]}" >&2
  fi
  exit 1
}
echo "$SUBMIT_OUT"

# 状态校验(成功才继续)
STATUS_LINE="$(echo "$SUBMIT_OUT" | grep -iE 'status:|Acceptable|Invalid|Rejected' | tail -1 || true)"
if echo "$STATUS_LINE" | grep -qiE 'Invalid|Rejected'; then
  echo "✗ 公证被拒绝:$STATUS_LINE" >&2
  exit 1
fi

# ── 4. Stapler ───────────────────────────────────────────────
echo "▶ Staple 公证票据到 ${APP} …"
xcrun stapler staple "$APP"
echo "▶ 验证 staple …"
xcrun stapler validate "$APP"

# ── 5. 重新 zip(staple 改变了 .app)──────────────────────────
echo "▶ 重新打包 staple 版 ${ZIP} …"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "✓ 公证 + Stapler 完成"
echo "  ${APP}  (stapled)"
echo "  ${ZIP}  (stapled zip,供上传)"