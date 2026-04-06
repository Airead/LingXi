.PHONY: test test-unit build build-release clean

SCHEME = LingXi
PROJECT = LingXi.xcodeproj
DESTINATION = platform=macOS
BUILD_DIR = $(CURDIR)/build

test: test-unit

test-unit:
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-parallel-testing-enabled NO \
		-only-testing LingXiTests

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

clean:
	xcodebuild clean \
		-project $(PROJECT) \
		-scheme $(SCHEME)
