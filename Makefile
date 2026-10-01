# Muses — 顶层构建/发布入口
#
# 用法:
#   make test        跑全量测试(--no-parallel,SpectrumTap 需串行)
#   make build       swift build(Debug)
#   make app         ad-hoc 签名的 dev .app(立即跑,未配置密钥时禁用自动更新)
#   make release     端到端:签名 + zip + 公证 + DMG
#                    需导出 MUSES_SIGN_IDENTITY / MUSES_NOTARY_PROFILE 等
#   make icon        生成 AppIcon.icns
#   make dmg         仅打 DMG(假设 build/Muses.app 已存在)
#   make ytdlp       拷入 yt-dlp 二进制到 Resources/
#   make clean       清除所有 build/ 和 .build/ 产物

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

SCRIPTS := Scripts
BUILD_DIR := build

# 默认 ad-hoc;正式发布用 `make release MUSES_SIGN_IDENTITY="Developer ID Application: ..."`
MUSES_SIGN_IDENTITY ?= -
MUSES_VERSION ?= 0.5.9
MUSES_BUILD ?= 20261001.3

.PHONY: all test build app release icon dmg ytdlp clean

all: app

test:
	swift test --no-parallel

build:
	swift build

app: $(SCRIPTS)/build-app.sh
	MUSES_VERSION="$(MUSES_VERSION)" MUSES_BUILD="$(MUSES_BUILD)" ./$(SCRIPTS)/build-app.sh --identity "$(MUSES_SIGN_IDENTITY)"

# 端到端发布:build-app → sign-update(打 zip)→ notarize → make-dmg
# A signed appcast is generated after the final DMG is notarized.
# Publish explicitly with Scripts/publish-update.sh; make release does not publish.
# 需在调用前 export:
#   MUSES_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   MUSES_NOTARY_PROFILE="muses"   (xcrun notarytool keychain profile)
#   MUSES_VERSION=0.5.0
release:
	MUSES_AUTOMATIC_UPDATES_REQUIRED=YES MUSES_SIGN_IDENTITY="$(MUSES_SIGN_IDENTITY)" MUSES_VERSION="$(MUSES_VERSION)" MUSES_BUILD="$(MUSES_BUILD)" ./$(SCRIPTS)/build-app.sh --identity "$(MUSES_SIGN_IDENTITY)"
	MUSES_VERSION="$(MUSES_VERSION)" ./$(SCRIPTS)/sign-update.sh
	MUSES_VERSION="$(MUSES_VERSION)" MUSES_NOTARIZATION_REQUIRED=YES ./$(SCRIPTS)/notarize.sh
	MUSES_VERSION="$(MUSES_VERSION)" MUSES_SIGN_IDENTITY="$(MUSES_SIGN_IDENTITY)" ./$(SCRIPTS)/make-dmg.sh
	MUSES_VERSION="$(MUSES_VERSION)" ./$(SCRIPTS)/notarize-dmg.sh
	MUSES_VERSION="$(MUSES_VERSION)" ./$(SCRIPTS)/sign-update.sh --appcast

icon: $(SCRIPTS)/make-icon.sh
	./$(SCRIPTS)/make-icon.sh

dmg: $(SCRIPTS)/make-dmg.sh
	MUSES_VERSION="$(MUSES_VERSION)" ./$(SCRIPTS)/make-dmg.sh

ytdlp: $(SCRIPTS)/copy-ytdlp.sh
	./$(SCRIPTS)/copy-ytdlp.sh

clean:
	rm -rf $(BUILD_DIR)
	rm -rf .build
