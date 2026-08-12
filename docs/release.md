# Muses 发布 Runbook

> Phase 4 发布管线文档。从源码到可公开分发的 DMG 完整流程。

## 前置(一次性)

### 1. Apple Developer ID(公开分发必需)
- 加入 [Apple Developer Program](https://developer.apple.com/programs/)($99/年,审批数天)
- 在Certificates, Identifiers & Profiles 申请 **Developer ID Application** 证书
- 导入到钥匙串,记下证书名:`Developer ID Application: Your Name (TEAMID)`

### 2. Sparkle EdDSA 签名密钥
```bash
# 生成密钥对(Sparkle CLI,存入 login keychain)
.build/artifacts/sparkle/Sparkle/bin/generate_keys

# 导出私钥到仓外文件(永不提交)
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/.muses/ed25519-priv.pem
chmod 600 ~/.muses/ed25519-priv.pem

# 公钥会打印在 generate_keys 的输出中,记下并备份
# sign-update.sh 会自动把公钥注入 Info.plist SUPublicEDKey
```

### 3. notarytool keychain profile(公证凭据)
- 在 [appleid.apple.com](https://appleid.apple.com) 创建 App-specific password
- 存入 keychain:
```bash
xcrun notarytool store-credentials muses \
  --apple-id you@example.com \
  --team-id XXXXXXXXXX \
  --password <app-specific-password>
```
- 之后用 `MUSES_NOTARY_PROFILE=muses` 即可

## 发布流程

### 快速:ad-hoc dev .app(立即可跑,无需任何凭据)
```bash
make app
# → build/Muses.app(ad-hoc 签名,Sparkle no-op)
open build/Muses.app
```

### 正式:端到端签名 + 公证 + DMG
```bash
export MUSES_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export MUSES_NOTARY_PROFILE=muses
export MUSES_VERSION=0.4.0

make release
# 1. build-app.sh    → build/Muses.app(Developer ID 签名)
# 2. sign-update.sh  → build/Muses-0.4.0.zip + build/appcast.xml(EdDSA 签名)
# 3. notarize.sh     → 公证 + Stapler + 重新 zip
# 4. make-dmg.sh     → build/Muses-0.4.0.dmg(签名)
```

或逐步执行:
```bash
MUSES_SIGN_IDENTITY="Developer ID Application: ..." make app
MUSES_VERSION=0.4.0 ./Scripts/sign-update.sh
MUSES_VERSION=0.4.0 MUSES_NOTARY_PROFILE=muses ./Scripts/notarize.sh
MUSES_VERSION=0.4.0 MUSES_SIGN_IDENTITY="Developer ID Application: ..." ./Scripts/make-dmg.sh
```

## 上传

1. **GitHub Release**(或任意 HTTPS 直链):
   - 挂 `build/Muses-0.4.0.zip`(公证 + stapled 版)
   - 挂 `build/Muses-0.4.0.dmg`(拖拽安装包)
   - 挂 `build/appcast.xml`(Sparkle 更新 feed)

2. **appcast.xml 托管**:
   - 上传到 HTTPS 地址,如 `https://your-host/muses/appcast.xml`
   - 更新 `Info.plist` 的 `SUFeedURL` 指向该地址
   - 重新 `make app` + `sign-update.sh` 生成最终 zip

3. **首次发布**:把 `SUPublicEDKey`(EdDSA 公钥)写入 `Info.plist` 后,
   后续所有版本用同一私钥签名;用户端 Sparkle 用公钥校验。

## 验证

```bash
# 产物结构
ls -la build/Muses.app/Contents/{MacOS,Resources,Frameworks}

# rpath(Sparkle.framework 定位)
otool -l build/Muses.app/Contents/MacOS/Muses | grep LC_RPATH -A2
# 应含 @executable_path/../Frameworks

# 签名
codesign --verify --deep --strict build/Muses.app && echo "✓ 签名 OK"
codesign -dvvv build/Muses.app

# 公证 + Stapler(正式发布后)
xcrun stapler validate build/Muses.app

# 启动冒烟
open build/Muses.app
# 检查:窗口出现、侧边栏可切换、播放控制菜单(⌘P/⌘←/⌘→)、设置→更新

# DMG 挂载
hdiutil attach build/Muses-0.4.0.dmg -nobrowse
ls /Volumes/Muses/  # 应含 Muses.app + Applications
hdiutil detach /Volumes/Muses
```

## 故障排查

| 症状 | 原因 | 解决 |
|------|------|------|
| `codesign --deep` 对 Sparkle.framework 报错 | framework 已签名 | build-app.sh 已处理:先签 yt-dlp 再 --deep |
| Sparkle 启动报 "misconfigured" | SUFeedURL/SUPublicEDKey 缺失 | dev 构建自动清空 SUFeedURL;正式发布用 sign-update.sh 注入 |
| notarytool submit 超时 | 网络或队列 | `xcrun notarytool history` 查状态;`notarytool log <id>` 查日志 |
| `install_name_tool` rpath 已存在 | 重复打包 | build-app.sh 幂等:先 otool 检查再 add |
| yt-dlp 签名失败 | 第三方 Python 二进制 | build-app.sh 对 yt-dlp 单独 ad-hoc 签 |

## 文件清单

| 文件 | 用途 |
|------|------|
| `Scripts/copy-ytdlp.sh` | 拷入 yt-dlp 二进制到 Resources/ |
| `Scripts/make-icon.sh` | icon.png → AppIcon.icns(iconutil) |
| `Scripts/build-app.sh` | 装配 .app + rpath + Sparkle.framework + codesign |
| `Scripts/sign-update.sh` | EdDSA 签名 zip + appcast.xml + 注入 SUPublicEDKey |
| `Scripts/notarize.sh` | notarytool submit + stapler(凭据缺失跳过) |
| `Scripts/make-dmg.sh` | hdiutil + ditto 拖拽安装 DMG |
| `Makefile` | 顶层入口:`make app/release/test/clean/...` |
| `Muses/Sources/Muses/Resources/Info.plist` | .app Info.plist 模板(SUFeedURL/SUPublicEDKey) |
| `Muses/Sources/Muses/Resources/Muses.entitlements` | hardened runtime entitlements |
| `Muses/Sources/Muses/Resources/appcast.xml` | Sparkle appcast 模板 |

## 安全与合规

- **个人使用,非 App Store**:Muses 为个人本地播放器,不经 App Store 分发。
- **yt-dlp 个人使用**:yt-dlp 二进制随包分发,仅供个人使用;遵守其 LICENSE。
- **YouTube 内容受 YouTube ToS 约束**:用户须自行确保使用合规。
- **EdDSA 私钥**:`~/.muses/ed25519-priv.pem` 存仓外,永不提交;丢失则无法签发后续更新。