# LarkReviewClient mac app — 构建与打包
# 用法:
#   make build    # swift build -c release
#   make bundle   # 组装并签名 build/LarkReviewClient.app
#   make run      # bundle 后启动
#   make test     # swift test
#   make clean

APP_NAME    := LarkReviewClient
BUILD_DIR   := build
APP         := $(BUILD_DIR)/$(APP_NAME).app
BIN         := $(shell swift build -c release --show-bin-path 2>/dev/null)/$(APP_NAME)

.PHONY: build bundle run test clean

build:
	swift build -c release

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" $(APP)/Contents/MacOS/$(APP_NAME)
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	codesign --force -s - $(APP)
	@echo "✓ $(APP)"

run: bundle
	open $(APP)

test:
	swift test

clean:
	swift package clean
	rm -rf $(BUILD_DIR)
