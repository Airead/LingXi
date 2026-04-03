.PHONY: test test-unit test-ui build clean

SCHEME = LingXi
PROJECT = LingXi.xcodeproj
DESTINATION = platform=macOS

test: test-unit test-ui

test-unit:
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-only-testing LingXiTests \
		| xcpretty || true

test-ui:
	xcodebuild test \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-only-testing LingXiUITests \
		| xcpretty || true

build:
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		| xcpretty || true

clean:
	xcodebuild clean \
		-project $(PROJECT) \
		-scheme $(SCHEME)
