.PHONY: test test-unit build clean

SCHEME = LingXi
PROJECT = LingXi.xcodeproj
DESTINATION = platform=macOS

test: test-unit

test-unit:
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-only-testing LingXiTests \
		| xcbeautify || true

build:
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		| xcbeautify || true

clean:
	xcodebuild clean \
		-project $(PROJECT) \
		-scheme $(SCHEME)
