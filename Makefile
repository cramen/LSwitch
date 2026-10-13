# xcode-select на этой машине указывает на Command Line Tools без XCTest,
# поэтому используем toolchain полного Xcode напрямую.
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

.PHONY: build test run lint

build:
	swift build

test:
	swift test

run:
	swift run lswitch

lint:
	swiftlint lint --strict
