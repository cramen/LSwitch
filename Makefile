# xcode-select на этой машине указывает на Command Line Tools без XCTest,
# поэтому используем toolchain полного Xcode напрямую.
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

.PHONY: build build-release test run lint app run-app run-app-refuse-ru run-app-refuse-en \
	check-recovery-protocol matrix-app

APP_DIR := .build/LSwitch.app

build:
	swift build

build-release:
	swift build -c release

test:
	swift test

# Чистые проверки App-протокола: без NSApplication, глобального tap и отправки событий.
check-recovery-protocol:
	mkdir -p .build
	xcrun swiftc -DDEBUG -parse-as-library Sources/LSwitch/RecoveryIsolationProtocol.swift \
		Sources/LSwitch/RecoveryIsolationMatrix.swift Sources/LSwitch/RecoveryIsolationChildMailbox.swift \
		Sources/LSwitch/RecoverySecureInputDiagnosticLease.swift Sources/LSwitch/RecoveryIsolationSecureWatchdog.swift \
		Sources/LSwitch/RecoveryDiagnosticPair.swift Tests/RecoveryIsolationHarness/RecoveryDiagnosticPairChecks.swift \
		Sources/LSwitch/RecoverySystemFaultContinuation.swift \
		Tests/RecoveryIsolationHarness/RecoverySystemFaultContinuationChecks.swift \
		Tests/RecoveryIsolationHarness/RecoveryIsolationMatrixChecks.swift \
		Tests/RecoveryIsolationHarness/RecoverySecureInputChecks.swift -o .build/recovery-matrix-checks
	.build/recovery-matrix-checks

run:
	swift run lswitch

lint:
	swiftlint lint --strict

# .app-бандл для ручной проверки спайков: разрешения TCC выдаются только
# бандлу с собственной идентичностью, а не голому бинарнику из терминала.
# Подпись self-signed сертификатом "LSwitch Dev" (dev-сертификат в login
# keychain): designated requirement привязан к сертификату, поэтому
# разрешения TCC ПЕРЕЖИВАЮТ пересборку — в отличие от ad-hoc (cdhash).
app:
	swift build -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
		-Xlinker $(CURDIR)/packaging/Info.plist
	mkdir -p $(APP_DIR)/Contents/MacOS
	cp .build/debug/lswitch $(APP_DIR)/Contents/MacOS/LSwitch
	cp packaging/Info.plist $(APP_DIR)/Contents/
	mkdir -p $(APP_DIR)/Contents/Resources
	cp -R .build/debug/LSwitch_LSwitchCore.bundle $(APP_DIR)/Contents/Resources/
	codesign --force --sign "LSwitch Dev" --identifier ru.cramen.lswitch $(APP_DIR)

run-app: app
	open $(APP_DIR)

# Изолированный GUI-приёмник имеет отдельную identity и не запускает обычный AppDelegate.
matrix-app: app
	swift build -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
		-Xlinker $(CURDIR)/packaging/RecoveryReceiver-Info.plist
	mkdir -p "$(APP_DIR)/Contents/Helpers/LSwitch Event Receiver.app/Contents/MacOS"
	cp .build/debug/lswitch \
		"$(APP_DIR)/Contents/Helpers/LSwitch Event Receiver.app/Contents/MacOS/LSwitchReceiver"
	cp packaging/RecoveryReceiver-Info.plist "$(APP_DIR)/Contents/Helpers/LSwitch Event Receiver.app/Contents/Info.plist"
	cp -R "$(APP_DIR)/Contents/Resources" "$(APP_DIR)/Contents/Helpers/LSwitch Event Receiver.app/Contents/"
	codesign --force --sign "LSwitch Dev" --identifier ru.cramen.lswitch.receiverprobe \
		"$(APP_DIR)/Contents/Helpers/LSwitch Event Receiver.app"
	codesign --force --sign "LSwitch Dev" --identifier ru.cramen.lswitch $(APP_DIR)

# Перед сменой режима завершить предыдущий экземпляр. Аргумент действует
# только в debug-сборке; после приёмки запускать обычный run-app.
run-app-refuse-ru: app
	open $(APP_DIR) --args --test-refuse-layout=ru

run-app-refuse-en: app
	open $(APP_DIR) --args --test-refuse-layout=en
