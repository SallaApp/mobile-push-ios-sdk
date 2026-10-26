# SallaPush iOS SDK. Run from the repository root. `make test-ios` needs Xcode with an iPhone simulator; `make lint`
# needs SwiftLint 0.63.2. `make verify` runs everything CI runs (scripts/verify.sh).

SHELL := /bin/bash

SWIFTLINT ?= swiftlint
SCHEME := SallaPush-Package
DERIVED_DATA := .build/DerivedData

# The newest iOS runtime's first iPhone.
NEWEST_IPHONE = xcrun simctl list devices available -j | python3 -c 'import json, re, sys; \
devices = json.load(sys.stdin)["devices"]; \
phones = [(tuple(int(part) for part in re.search(r"iOS-(\d+)-(\d+)", runtime).groups()), -index, device["udid"]) \
          for runtime, entries in devices.items() if re.search(r"iOS-\d+-\d+", runtime) \
          for index, device in enumerate(entries) if device["name"].startswith("iPhone")]; \
print(max(phones)[2] if phones else "")'

.PHONY: verify test test-ios tsan lint api gates

## Every check CI runs, in CI's order; STEPS="lint gates" runs only those steps.
verify:
	SWIFTLINT="$(SWIFTLINT)" scripts/verify.sh $(STEPS)

## Build and run every suite on macOS; every compiler warning is an error.
test:
	swift build -Xswiftc -warnings-as-errors
	swift test -Xswiftc -warnings-as-errors

## Run every suite on the newest iPhone simulator, plain and with Thread Sanitizer, serially (no simulator clones),
## then build the extension product with the extension-only API set.
test-ios:
	set -euo pipefail; \
	udid="$$($(NEWEST_IPHONE))"; \
	if [ -z "$$udid" ]; then echo "test-ios: no iPhone simulator is available" >&2; exit 1; fi; \
	xcodebuild test -scheme $(SCHEME) -destination "platform=iOS Simulator,id=$$udid" \
		-parallel-testing-enabled NO -derivedDataPath $(DERIVED_DATA); \
	xcodebuild test -scheme $(SCHEME) -destination "platform=iOS Simulator,id=$$udid" \
		-parallel-testing-enabled NO -derivedDataPath $(DERIVED_DATA) -enableThreadSanitizer YES
	xcodebuild build -scheme SallaPushExtension -destination 'generic/platform=iOS' \
		-derivedDataPath $(DERIVED_DATA) APPLICATION_EXTENSION_API_ONLY=YES

## Run every suite on macOS with Thread Sanitizer; every compiler warning is an error.
tsan:
	swift test --sanitize=thread -Xswiftc -warnings-as-errors

## SwiftLint with the crash-safety rules as errors.
lint:
	$(SWIFTLINT) lint --strict --config .swiftlint.yml

## Fail when the public API differs from API.txt (scripts/api-surface.sh rewrites it).
api:
	scripts/api-surface.sh --check

## The grep gates and the no-dependencies check.
gates:
	scripts/check-gates.sh
