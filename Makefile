.PHONY: test test-unit test-capture-service build build-release clean install

SCHEME = LingXi
PROJECT = LingXi.xcodeproj
DESTINATION = platform=macOS
BUILD_DIR = $(CURDIR)/build
APP_NAME = LingXi.app
INSTALL_DIR = /Applications

test: test-unit

test-unit:
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-parallel-testing-enabled NO \
		-only-testing LingXiTests

test-capture-service:
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-parallel-testing-enabled NO \
		-only-testing LingXiTests/ScreenCaptureServiceTests

build:
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		| xcbeautify || true

build-release:
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-configuration Release \
		SYMROOT=$(BUILD_DIR) \
		| xcbeautify || true

install: build-release
	@echo "Installing $(APP_NAME) to $(INSTALL_DIR)..."
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	cp -R "$(BUILD_DIR)/Release/$(APP_NAME)" "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Done."

clean:
	xcodebuild clean \
		-project $(PROJECT) \
		-scheme LingXi
	xcodebuild clean \
		-project $(PROJECT) \
		-scheme LingXiCaptureService
