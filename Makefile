# Muses — 顶层构建/发布入口
#
# 用法:
#   make test        跑全量测试(--no-parallel,SpectrumTap 需串行)
#   make build       swift build(Debug)
#   make app         ad-hoc 签名的 dev .app(立即跑,更新检查走 GitHub API)
#   make release     端到端:签名 + zip + 公证 + DMG
#                    需导出 MUSES_SIGN_IDENTITY / MUSES_NOTARY_PROFILE 等
#   make icon        生成 AppIcon.icns
#   make dmg         仅打 DMG(假设 build/Muses.app 已存在)
#   make ytdlp       拷入 yt-dlp 二进制到 Resources/
#   make clean       清 build/ 与 .build/release(保留 .build 供 test)

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

SCRIPTS := Scripts
BUILD_DIR := build

# 默认 ad-hoc;正式发布用 `make release MUSES_SIGN_IDENTITY="Developer ID Application: ..."`
MUSES_SIGN_IDENTITY ?= -
MUSES_VERSION ?= 0.4.0

.PHONY: all test build app release icon dmg ytdlp clean

all: app

test:
	swift test --no-parallel

build:
	swift build

app: $(SCRIPTS)/build-app.sh
	./$(SCRIPTS)/build-app.sh --identity "$(MUSES_SIGN_IDENTITY)"

# 端到端发布:build-app → sign-update(打 zip)→ notarize → make-dmg
# zip 上传到 GitHub Release 后,UpdateService 自动发现新版本(releases/latest)。
# 需在调用前 export:
#   MUSES_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   MUSES_NOTARY_PROFILE="muses"   (xcrun notarytool keychain profile)
#   MUSES_VERSION=0.4.0
release: app
	MUSES_VERSION="$(MUSES_VERSION)" ./$(SCRIPTS)/sign-update.sh
	MUSES_VERSION="$(MUSES_VERSION)" ./$(SCRIPTS)/notarize.sh
	MUSES_VERSION="$(MUSES_VERSION)" ./$(SCRIPTS)/make-dmg.sh

icon: $(SCRIPTS)/make-icon.sh
	./$(SCRIPTS)/make-icon.sh

dmg: $(SCRIPTS)/make-dmg.sh
	MUSES_VERSION="$(MUSES_VERSION)" ./$(SCRIPTS)/make-dmg.sh

ytdlp: $(SCRIPTS)/copy-ytdlp.sh
	./$(SCRIPTS)/copy-ytdlp.sh

clean:
	rm -rf $(BUILD_DIR)
	rm -rf .build/release