# xcode-select на этой машине указывает на Command Line Tools без XCTest,
# поэтому используем toolchain полного Xcode напрямую.
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

.PHONY: build test run lint app run-app

APP_DIR := .build/LSwitch.app

build:
	swift build

test:
	swift test

run:
	swift run lswitch

lint:
	swiftlint lint --strict

# .app-бандл для ручной проверки спайков: разрешения TCC выдаются только
# бандлу с собственной идентичностью, а не голому бинарнику из терминала.
# Ad-hoc подпись с фиксированным identifier; НЕ пересобирай между выдачей
# разрешений и проверками — сигнатура изменится, и разрешения слетят.
app:
	swift build -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
		-Xlinker $(CURDIR)/packaging/Info.plist
	mkdir -p $(APP_DIR)/Contents/MacOS
	cp .build/debug/lswitch $(APP_DIR)/Contents/MacOS/LSwitch
	cp packaging/Info.plist $(APP_DIR)/Contents/
	codesign --force --sign - --identifier ru.cramen.lswitch $(APP_DIR)

run-app: app
	open $(APP_DIR)
