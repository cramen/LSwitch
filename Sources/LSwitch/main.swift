import AppKit
import Combine
import LSwitchCore
import os

/// Точка входа menu-bar агента LSwitch.
///
/// MVP (этап 1): двойной Shift конвертирует последнее слово
/// (AX-first, clipboard-fallback) и переключает раскладку, повторный —
/// откат. Список исключений приложений, PermGuard, настройки, автозапуск.
/// Диагностический режим спайков сохранён: `lswitch --probe`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let logger = Logger(subsystem: "LSwitch", category: "App")

    private lazy var statusMenu = StatusMenuController()
    private let permissionNotice = PermissionNoticeController()
    var settingsWindow: NSWindow?

    let settings = SettingsStore()
    lazy var hotkeySettings: HotkeySettingsController = {
        let controller = HotkeySettingsController(settings: settings)
        controller.onChange = { [weak self] in self?.resetInputContext() }
        return controller
    }()
    let appRules = AppRules()
    let personalDictionary = PersonalDictionary()
    private let layoutManager = LayoutManager()
    private let undoStore = UndoStore()
    private let permGuard = PermGuard()
    private let soundFeedback = SoundFeedbackController()
    private let keystrokeBuffer = KeystrokeBuffer()
    private let classifier = KeystrokeClassifier()
    private lazy var autoSwitch = AutoSwitchCoordinator(
        classifier: WordClassifier(personalDictionary: personalDictionary), personalDictionary: personalDictionary
    )
    private let appProfiles = AppProfiles()
    private var detector = ConversionHotkeyDetector()
    private var eventTap: EventTapCore?
    private var inputHoldingTap: EventTapCore?
    private let conversions = AppConversionDispatch()
    private lazy var converter = makeConverter()
    private var inputGeneration: UInt64 = 0
    private var interceptionGeneration: UInt64 = 0
    #if DEBUG
    private var diagnosticsSession: DiagnosticsSession?
    #endif

    private var workspaceObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    private func currentFrontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        do {
            diagnosticsSession = try DiagnosticsSession.from(arguments: CommandLine.arguments)
        } catch {
            logger.error("Не удалось начать диагностику: \(error.localizedDescription, privacy: .public)")
        }
        #endif
        guard conversions.configure(eventTap: { [weak self] in self?.eventTap }, currentSafety: { [weak self] in
            guard let self else { return false }
            return self.settings.enabled && self.permGuard.current.allGranted && self.eventTap != nil
        }, onAvailability: { [weak self] in self?.statusMenu.setRecoveryAvailable($0) }) else {
            logger.error("Pilot требует абсолютный путь отдельного тестового документа")
            NSApplication.shared.terminate(nil)
            return
        }
        setupStatusItem()
        setupPermGuard()
        observeWorkspace()
        requestPermissionsIfNeeded()
        let prepared = DictionaryStore.shared.prewarm()
        if !prepared.isReady { logger.error("Словари недоступны для автоматической конвертации") }
        settings.$soundEnabled.sink { [soundFeedback] enabled in
            soundFeedback.setEnabled(enabled)
        }.store(in: &cancellables)
        startInterception()
        // Окно отката следует за настройкой (spec settings).
        settings.$undoWindowSeconds
            .assign(to: \.window, on: undoStore)
            .store(in: &cancellables)
        settings.$undoLearningThreshold
            .assign(to: \.learningThreshold, on: autoSwitch)
            .store(in: &cancellables)
        settings.$enabled.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] enabled in
            guard let self else { return }
            self.permGuard.checkNow()
            if enabled { self.startInterception() } else {
                self.conversions.disabled()
                self.stopInterception()
            }
            self.refreshMenuStatus()
        }.store(in: &cancellables)
        logger.info("TIS источники: \(self.layoutManager.enabledSourceIDs())")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        conversions.requestQuit { sender.reply(toApplicationShouldTerminate: $0) } ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopInterception()
        soundFeedback.shutdown()
        #if DEBUG
        diagnosticsSession?.finish()
        #endif
    }

    /// Повторное открытие menu-bar приложения даёт доступ к его настройкам.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: - Перехват → детект → конвертация

    private func startInterception() {
        guard eventTap == nil, settings.enabled, permGuard.current.allGranted else { return }
        interceptionGeneration &+= 1
        let generation = interceptionGeneration
        let tap = EventTapCore { [weak self] raw in
            DispatchQueue.main.async {
                guard let self, self.interceptionGeneration == generation,
                      self.eventTap?.acceptsForProcessing(raw) == true else { return }
                self.handleIntercepted(raw)
            }
        }
        tap.onRecoveryStarted = { [weak self] _ in
            self?.conversions.tapLost()
            self?.resetInputContext()
        }
        #if DEBUG
        diagnosticsSession?.attach(tap)
        #endif
        guard tap.start() else {
            logger.error("Event tap не запущен — нет разрешений?")
            return
        }
        eventTap = tap
        hotkeySettings.setActive(true)
        #if DEBUG
        diagnosticsSession?.sample(reason: "tapStarted")
        #endif
    }

    private func stopInterception() {
        hotkeySettings.setActive(false)
        interceptionGeneration &+= 1
        resetInputContext()
        eventTap?.stop()
        #if DEBUG
        diagnosticsSession?.detach()
        #endif
        eventTap = nil
    }

    /// Callback tap передаёт сюда события на главный поток.
    private func handleIntercepted(_ raw: RawKeyEvent) {
        guard !raw.isSynthetic else { return }
        let hotkeyResult = detector.handle(raw, hotkey: hotkeySettings.activeHotkey)
        guard settings.enabled, permGuard.current.allGranted, eventTap != nil, raw.type != .other,
              !appRules.isBlocked(bundleID: currentFrontmostBundleID()),
              let target = InputSafety.captureTarget() else {
            resetInputContext()
            return
        }
        if hotkeyResult == .consumed { return }
        if hotkeyResult == .trigger {
            // Ожидаемое слово из буфера — для точного выделения ⇧←×N
            // в clipboard-режиме (Electron гранулярности не доверяем).
            let word = keystrokeBuffer.lastWord()
            let generation = inputGeneration
            Task { [converter, autoSwitch] in
                guard self.settings.enabled, self.inputGeneration == generation, target.isCurrent() else { return }
                await self.conversions.perform(operation: {
                    await converter.trigger(expectedWord: word.isEmpty ? nil : word, triggerTimestamp: raw.timestamp)
                }, applyOutcome: { outcome in
                    switch outcome {
                    case .undone, .partiallyUndone:
                        autoSwitch.registerUndo()
                        self.keystrokeBuffer.clear()
                    case .converted, .partiallyConverted:
                        autoSwitch.clearPendingUndoCandidate()
                        self.keystrokeBuffer.clear()
                    default: break
                    }
                    self.statusMenu.showOutcome(outcome)
                    self.logger.info("Хоткей: \(outcome.label, privacy: .public)")
                }, reset: { self.resetInputContext() }, consume: { self.handleIntercepted($0) })
            }
            return
        }
        handleTypedInput(raw, target: target)
    }

    private func handleTypedInput(_ raw: RawKeyEvent, target: InputTarget) {
        if raw.type == .keyDown, !raw.isSynthetic {
            inputGeneration &+= 1
            converter.notifyOtherKeystroke()
        }
        if let kind = classifier.classify(raw) {
            keystrokeBuffer.append(Keystroke(kind: kind, isSynthetic: raw.isSynthetic))
            // Триггер: разделители И пунктуация с маппингом («ghbdtn,» —
            // запятая и разделитель, и триггер; TZ.md F10).
            if settings.autoSwitchEnabled, isAutoSwitchTrigger(kind) {
                maybeAutoConvert(target: target, triggerTimestamp: raw.timestamp)
            }
        }
    }

    private func isAutoSwitchTrigger(_ kind: Keystroke.Kind) -> Bool {
        switch kind {
        case .delimiter:
            return true
        case .character(let char):
            // Маппируемая пунктуация хранится как character, но слово завершает.
            return !char.isLetter && !char.isNumber
        case .control:
            return false
        }
    }

    /// Автопереключение: разделитель набран, проверяем последнее слово.
    /// Запрос содержит всё от начала слова до текущей каретки.
    private func maybeAutoConvert(target: InputTarget, triggerTimestamp: UInt64) {
        guard let bufferedContext = keystrokeBuffer.lastWordContextForAutoSwitch(),
              let context = autoSwitch.evaluate(context: bufferedContext) else { return }
        logger.notice("Автоконвертация слова длиной \(context.word.count)")
        let generation = inputGeneration
        let bundleID = currentFrontmostBundleID()
        Task { [converter, autoSwitch] in
            let rejection: ConversionDiagnostics.Rejection?
            if !self.settings.enabled {
                rejection = .rules
            } else if self.inputGeneration != generation {
                rejection = .generationChanged
            } else if self.currentFrontmostBundleID() != bundleID {
                rejection = .applicationChanged
            } else {
                rejection = target.invalidationReason
            }
            if let rejection {
                converter.recordSkippedAutomatic(
                    triggerTimestamp: triggerTimestamp, bundleID: bundleID, reason: rejection
                )
                return
            }
            await self.conversions.perform(operation: {
                await converter.trigger(expectedWord: context.word, trailingText: context.trailingText,
                                        allowUndo: false, triggerTimestamp: triggerTimestamp)
            }, applyOutcome: { outcome in
                switch outcome {
                case .converted, .partiallyConverted: self.keystrokeBuffer.clear()
                default: autoSwitch.clearPendingUndoCandidate()
                }
                self.statusMenu.showOutcome(outcome)
                self.logger.info("Автоконвертация: \(outcome.label, privacy: .public)")
            }, reset: { self.resetInputContext() }, consume: { self.handleIntercepted($0) })
        }
    }

    private func resetInputContext() {
        inputGeneration &+= 1
        keystrokeBuffer.clear()
        detector.resetSequence()
        converter.notifyOtherKeystroke()
        autoSwitch.clearPendingUndoCandidate()
    }

    // MARK: - PermGuard

    private func setupPermGuard() {
        permGuard.onPermissionsLost = { [weak self] status in
            guard let self else { return }
            self.logger.notice("Не хватает разрешений — перехват остановлен")
            self.conversions.permissionsLost()
            self.stopInterception()
            self.permissionNotice.show(status)
        }
        permGuard.onPermissionsRestored = { [weak self] in
            guard let self else { return }
            self.logger.notice("Разрешения восстановлены")
            self.startInterception()
        }
        permGuard.onStatusChanged = { [weak self] status in
            self?.permissionNotice.update(status)
            self?.refreshMenuStatus()
        }
        permGuard.start()
    }

    private func requestPermissionsIfNeeded() {
        permissionNotice.show(permGuard.current)
    }

    /// Смена приложения завершает прежний контекст ввода и отмены.
    private func observeWorkspace() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.conversions.focusChanged()
                self?.resetInputContext()
            }
        }
    }

    // MARK: - Меню

    private func setupStatusItem() {
        statusMenu.onToggle = { [weak self] in self?.settings.enabled.toggle() }
        statusMenu.onRecovery = { [weak self] in self?.conversions.showRecovery() }
        statusMenu.onSettings = { [weak self] in self?.openSettings() }
        statusMenu.onPermissions = { [weak self] in
            guard let self else { return }
            self.permGuard.checkNow()
            self.permissionNotice.show(self.permGuard.current, force: true)
        }
        statusMenu.onRefresh = { [weak self] in
            self?.permGuard.checkNow()
            self?.refreshMenuStatus()
        }
        refreshMenuStatus()
    }

    private func refreshMenuStatus() {
        statusMenu.update(enabled: settings.enabled, status: permGuard.current)
    }

}

extension AppDelegate {
    private func makeConverter() -> Converter {
        Converter(
            currentLayout: { [layoutManager] in layoutManager.currentLayout() },
            switchLayout: { [layoutManager] layout in
                #if DEBUG
                let direction = layout == .russian ? "ru" : "en"
                if CommandLine.arguments.contains("--test-refuse-layout=\(direction)") { return false }
                #endif
                return layoutManager.switchTo(layout)
            },
            appRules: appRules,
            undoStore: undoStore,
            frontmostBundleID: { [weak self] in self?.currentFrontmostBundleID() },
            prefersClipboard: { [appProfiles] in
                AcceptanceOptions.prefersClipboard(defaultValue: appProfiles.prefersClipboard(bundleID: $0))
            },
            makeAXEngine: { AXConversionEngine() },
            makeClipboardEngine: { AcceptanceOptions.makeClipboardEngine() },
            makeUnicodeEngine: { AcceptanceOptions.makeUnicodeEngine(bundleID: $0) },
            recoverySessionFactory: conversions.factory, recoveryOwner: conversions.owner,
            beginInputHold: { [weak self] in
                guard let self, let tap = self.eventTap, tap.beginInputHold() else { return false }
                self.inputHoldingTap = tap
                return true
            },
            endInputHold: { [weak self] in
                self?.inputHoldingTap?.endInputHold()
                self?.inputHoldingTap = nil
            },
            isInputHoldValid: { [weak self] in self?.inputHoldingTap?.isInputHeld == true },
            drainPendingInput: { [weak self] in await self?.inputHoldingTap?.drainPendingEvents() },
            onLayoutSwitched: { [weak self] source, target, startedAt in
                self?.eventTap?.recordLayoutChange(from: source, to: target, since: startedAt)
            },
            onConverted: { [weak self] in
                guard let self, self.settings.soundEnabled else { return }
                self.soundFeedback.conversionSucceeded()
            }
        )
    }
}

if let status = MainActor.assumeIsolated({ StartupCommands.runIfRequested(arguments: CommandLine.arguments) }) {
    exit(status)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Агент строки меню: без иконки в Dock.
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
