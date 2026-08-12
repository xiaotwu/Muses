#!/bin/bash
# sign-update.sh — Sparkle EdDSA 签名 + appcast 注入
#
# 前置:build/Muses.app 已由 build-app.sh 产出。
# 产物:
#   build/Muses-$VER.zip           带 EdDSA 签名的更新包
#   build/appcast.xml              Sparkle appcast(含新 <item>)
#   ~/.muses/ed25519-priv.pem      EdDSA 私钥(仓外,不提交)
#   ~/.muses/ed25519-pub.txt       EdDSA 公钥(注入 Info.plist SUPublicEDKey)
#
# 用法:
#   MUSES_VERSION=0.4.0 ./Scripts/sign-update.sh
#   # 或跳过 appcast 注入,仅签名:
#   MUSES_VERSION=0.4.0 ./Scripts/sign-update.sh --skip-appcast
#
# dev 模式(MUSES_SIGN_IDENTITY 为 "-" 且无私钥):跳过签名,exit 0。

set -euo pipefail

VER="${MUSES_VERSION:-0.4.0}"
APP="build/Muses.app"
ZIP="build/Muses-${VER}.zip"
APPCAST_OUT="build/appcast.xml"
KEY_DIR="${HOME}/.muses"
PRIV_KEY="${KEY_DIR}/ed25519-priv.pem"
PUB_KEY="${KEY_DIR}/ed25519-pub.txt"
SPARKLE_BIN="$(pwd)/.build/artifacts/sparkle/Sparkle/bin"
SIGN_UPDATE="${SPARKLE_BIN}/sign_update"
GENERATE_KEYS="${SPARKLE_BIN}/generate_keys"
SKIP_APPCAST=0

for arg in "$@"; do
  case "$arg" in
    --skip-appcast) SKIP_APPCAST=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
  esac
done

cd "$(dirname "$0")/.."

# ── 1. 前置检查 ──────────────────────────────────────────────
if [[ ! -d "$APP" ]]; then
  echo "✗ 找不到 ${APP};请先 ./Scripts/build-app.sh" >&2
  exit 1
fi
if [[ ! -x "$SIGN_UPDATE" ]]; then
  echo "✗ 找不到 Sparkle CLI: ${SIGN_UPDATE}" >&2
  echo "  请先 swift build(Sparkle 依赖解析后产出 CLI 工具)" >&2
  exit 1
fi

# ── 2. EdDSA 密钥(仓外)──────────────────────────────────────
if [[ ! -f "$PRIV_KEY" ]]; then
  # dev 模式且未显式要求签名 → 跳过
  if [[ "${MUSES_SIGN_IDENTITY:--}" == "-" && ! -f "$PUB_KEY" ]]; then
    echo "ℹ dev 模式:未配置 EdDSA 私钥,跳过签名(appcast 不会生成)"
    echo "  正式发布请先运行: ${GENERATE_KEYS} 生成密钥"
    exit 0
  fi
  echo "▶ 生成 EdDSA 密钥对(Sparkle Keychain)…"
  mkdir -p "$KEY_DIR"
  chmod 700 "$KEY_DIR"
  # generate_keys 生成到 login keychain,stdout 打印公钥
  PUB_OUT="$("$GENERATE_KEYS" 2>/dev/null || true)"
  # 导出私钥到文件
  "$GENERATE_KEYS" -x "$PRIV_KEY" 2>/dev/null || true
  chmod 600 "$PRIV_KEY"
  # 提取公钥(generate_keys 输出形如 "pub key: <base64>" 或纯 base64)
  echo "$PUB_OUT" | grep -oE '[A-Za-z0-9+/]{40,}' | head -1 > "$PUB_KEY" || true
  if [[ ! -s "$PUB_KEY" ]]; then
    echo "$PUB_OUT" > "$PUB_KEY"
  fi
  chmod 600 "$PUB_KEY"
  echo "✓ 私钥: ${PRIV_KEY}"
  echo "✓ 公钥: ${PUB_KEY}"
  echo "  ⚠ 请备份私钥;公钥将注入 Info.plist SUPublicEDKey"
fi

PUB_BASE64="$(cat "$PUB_KEY" | tr -d '[:space:]' | head -1)"

# ── 3. 打 zip ────────────────────────────────────────────────
echo "▶ 打包 ${ZIP} …"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# ── 4. EdDSA 签名 ─────────────────────────────────────────────
echo "▶ 签名(zip)…"
SIG_OUT="$("$SIGN_UPDATE" "$ZIP" --ed-key-file "$PRIV_KEY" 2>&1 || true)"
echo "$SIG_OUT"
# 输出形如:sparkle:edSignature=<base64> length=<n>
ED_SIG="$(echo "$SIG_OUT" | grep -oE 'edSignature=[A-Za-z0-9+/=]+' | cut -d= -f2 | head -1)"
LEN="$(echo "$SIG_OUT" | grep -oE 'length=[0-9]+' | cut -d= -f2 | head -1)"
if [[ -z "$ED_SIG" || -z "$LEN" ]]; then
  echo "✗ 未能解析 sign_update 输出(edSignature/length)" >&2
  exit 1
fi

# ── 5. 注入 SUPublicEDKey 到 .app 的 Info.plist ───────────────
echo "▶ 注入 SUPublicEDKey 到 Info.plist …"
PLIST="${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey ${PUB_BASE64}" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string ${PUB_BASE64}" "$PLIST"

# ── 6. appcast.xml ────────────────────────────────────────────
if [[ "$SKIP_APPCAST" == "1" ]]; then
  echo "ℹ --skip-appcast:跳过 appcast 生成"
  echo "✓ 完成: ${ZIP}"
  exit 0
fi

PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
FEED_URL="$(PlistBuddy -c 'Print :SUFeedURL' "$PLIST" 2>/dev/null || echo 'https://muses.example/appcast.xml')"
# enclosure URL:feed host + zip 文件名(发布者上传后可改)
ENC_URL="$(echo "$FEED_URL" | sed 's|/[^/]*$|/')Muses-${VER}.zip"

# 读取现有 appcast(若 build/appcast.xml 不存在,用模板)
TEMPLATE="Muses/Sources/Muses/Resources/appcast.xml"
if [[ -f "$APPCAST_OUT" ]]; then
  SOURCE="$APPCAST_OUT"
else
  SOURCE="$TEMPLATE"
fi

# 用 Python 构建新 appcast:解析现有,移除同版本 item,插入新 item
python3 - "$SOURCE" "$APPCAST_OUT" "$VER" "$PUBDATE" "$ED_SIG" "$LEN" "$ENC_URL" <<'PY'
import sys, datetime, xml.etree.ElementTree as ET
src, dst, ver, pubdate, ed_sig, length, enc_url = sys.argv[1:8]
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
ET.register_namespace('sparkle', ns['sparkle'])
tree = ET.parse(src)
root = tree.getroot()
channel = root.find('channel')
# 移除已有同版本 item
for it in list(channel.findall('item')):
    sv = it.find('sparkle:version', ns)
    if sv is not None and sv.text == ver:
        channel.remove(it)
# 新 item
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = f'Version {ver}'
ET.SubElement(item, 'pubDate').text = pubdate
sv = ET.SubElement(item, '{http://www.andymatuschak.org/xml-namespaces/sparkle}version')
sv.text = ver
svvs = ET.SubElement(item, '{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString')
svvs.text = ver
enc = ET.SubElement(item, 'enclosure', {
    'url': enc_url,
    '{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature': ed_sig,
    'length': length,
    'type': 'application/octet-stream',
})
ET.SubElement(item, 'description').text = f'<ul><li>Muses {ver}</li></ul>'
tree.write(dst, encoding='utf-8', xml_declaration=True)
PY

echo "✓ appcast: ${APPCAST_OUT}"
echo
echo "═══════════════════════════════════════════════════════"
echo " 发布产物:"
echo "   ${ZIP}              → 上传到 GitHub Release / 直链"
echo "   ${APPCAST_OUT}      → 上传到 SUFeedURL 指向的 HTTPS 地址"
echo "   SUPublicEDKey 已注入 ${PLIST}"
echo "═══════════════════════════════════════════════════════"