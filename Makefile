APP_NAME = KeychronBatteryMonitor
BUNDLE_ID = com.keychron.battery-monitor
VERSION = $(shell git describe --tags --abbrev=0 2>/dev/null || echo "1.0.0")
BUILD_DIR = .build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS = $(APP_BUNDLE)/Contents

.PHONY: build app dmg clean run

build:
	swift build -c release

app: build
	@echo "Creating .app bundle..."
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS"
	@mkdir -p "$(CONTENTS)/Resources"
	@cp "$(BUILD_DIR)/release/$(APP_NAME)" "$(CONTENTS)/MacOS/"
	@cp "Info.plist" "$(CONTENTS)/"
	@# Patch version into Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" "$(CONTENTS)/Info.plist"
	@echo "Built: $(APP_BUNDLE)"

dmg: app
	@echo "Creating .dmg..."
	@hdiutil create -volname "$(APP_NAME)" \
		-srcfolder "$(APP_BUNDLE)" \
		-ov -format UDZO \
		"$(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg"
	@echo "Created: $(BUILD_DIR)/$(APP_NAME)-$(VERSION).dmg"

run: build
	swift run

clean:
	swift package clean
	rm -rf "$(APP_BUNDLE)" "$(BUILD_DIR)/"*.dmg
