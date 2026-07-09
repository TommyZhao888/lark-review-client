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
DMG         := $(BUILD_DIR)/$(APP_NAME).dmg
BIN         := $(shell swift build -c release --show-bin-path 2>/dev/null)/$(APP_NAME)

.PHONY: build bundle run test clean dmg

build:
	swift build -c release

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp "$$(swift build -c release --show-bin-path)/$(APP_NAME)" $(APP)/Contents/MacOS/$(APP_NAME)
	printf 'APPL????' > $(APP)/Contents/PkgInfo
	codesign --force -s - $(APP)
	@echo "✓ $(APP)"

run: bundle
	open $(APP)

# 打成 .dmg(挂载后把 App 拖进 Applications 即装; 免解压)。CI 与手动分发共用。
dmg: bundle
	rm -f $(DMG)
	rm -rf $(BUILD_DIR)/dmg-stage
	mkdir -p $(BUILD_DIR)/dmg-stage
	cp -R $(APP) $(BUILD_DIR)/dmg-stage/
	ln -s /Applications $(BUILD_DIR)/dmg-stage/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder $(BUILD_DIR)/dmg-stage -ov -format UDZO $(DMG)
	rm -rf $(BUILD_DIR)/dmg-stage
	@echo "✓ $(DMG)"

test:
	swift test

clean:
	swift package clean
	rm -rf $(BUILD_DIR)
