import AppKit
import Combine
import LSwitchCore
import os
import SwiftUI

/// Точка входа menu-bar агента LSwitch.
///
/// MVP (этап 1): двойной Shift конвертирует последнее слово
/// (AX-first, clipboard-fallback) и переключает раскладку, повторный —
/// откат. Список исключений приложений, PermGuard, настройки, автозапуск.
/// Диагностический режим спайков сохранён: `lswitch --probe`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let logger = Logger(subsystem: "LSwitch", category: "App")

    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var permissionsItem: NSMenuItem!
    private var settingsWindow: NSWindow?

    private let settings = SettingsStore()
    private let appRules = AppRules()
    private let personalDictionary = PersonalDictionary()
    private let layoutManager = LayoutManager()
    private let undoStore = UndoStore()
    private let permGuard = PermGuard()
    private let keystrokeBuffer = KeystrokeBuffer()
    private let classifier = KeystrokeClassifier()
    private let autoSwitch = AutoSwitchCoordinator()
    private let appProfiles = AppProfiles()
    private var detector = DoubleShiftDetector()
    private var eventTap: EventTapCore?
    private var inputHoldingTap: EventTapCore?
    private lazy var converter = makeConverter()
    private var inputGeneration: UInt64 = 0

    private var workspaceObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    private func currentFrontmostBundleID() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPermGuard()
        observeWorkspace()
        requestPermissionsIfNeeded()
        startInterception()
        // Окно отката следует за настройкой (spec settings).
        settings.$undoWindowSeconds
            .assign(to: \.window, on: undoStore)
            .store(in: &cancellables)
        settings.$enabled.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] enabled in
            guard let self else { return }
            if enabled { self.startInterception() } else { self.stopInterception() }
            self.updateToggleItem()
        }.store(in: &cancellables)
        logger.info("TIS источники: \(self.layoutManager.enabledSourceIDs())")
    }

    /// Повторное открытие menu-bar приложения даёт доступ к его настройкам.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: - Перехват → детект → конвертация

    private func startInterception() {
        guard eventTap == nil, settings.enabled else { return }
        let tap = EventTapCore { [weak self] raw in
            DispatchQueue.main.async { self?.handleIntercepted(raw) }
        }
        guard tap.start() else {
            logger.error("Event tap не запущен — нет разрешений?")
            return
        }
        eventTap = tap
    }

    private func stopInterception() {
        resetInputContext()
        eventTap?.stop()
        eventTap = nil
    }

    /// Callback tap передаёт сюда события на главный поток.
    private func handleIntercepted(_ raw: RawKeyEvent) {
        guard !raw.isSynthetic else { return }
        guard settings.enabled, raw.type != .other,
              !appRules.isBlocked(bundleID: currentFrontmostBundleID()),
              let target = InputSafety.captureTarget() else {
            resetInputContext()
            return
        }
        if detector.handle(raw) {
            // Ожидаемое слово из буфера — для точного выделения ⇧←×N
            // в clipboard-режиме (Electron гранулярности не доверяем).
            let word = keystrokeBuffer.lastWord()
            let generation = inputGeneration
            Task { [converter, autoSwitch] in
                guard self.settings.enabled, self.inputGeneration == generation, target.isCurrent() else { return }
                let outcome = await converter.trigger(expectedWord: word.isEmpty ? nil : word)
                if case .undone = outcome {
                    // Откат автоконвертации — сигнал обучения (design D4).
                    autoSwitch.registerUndo()
                } else if case .converted = outcome {
                    autoSwitch.clearPendingUndoCandidate()
                    self.keystrokeBuffer.clear()
                }
                self.logger.info("Хоткей: \(outcome.label, privacy: .public)")
            }
            return
        }
        if raw.type == .keyDown, !raw.isSynthetic {
            inputGeneration &+= 1
            converter.notifyOtherKeystroke()
        }
        if let kind = classifier.classify(raw) {
            keystrokeBuffer.append(Keystroke(kind: kind, isSynthetic: raw.isSynthetic))
            // Триггер: разделители И пунктуация с маппингом («ghbdtn,» —
            // запятая и разделитель, и триггер; TZ.md F10).
            if settings.autoSwitchEnabled, isAutoSwitchTrigger(kind) {
                maybeAutoConvert(target: target)
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
    private func maybeAutoConvert(target: InputTarget) {
        guard let context = keystrokeBuffer.lastWordContextForAutoSwitch(),
              autoSwitch.evaluate(word: context.word) != nil else { return }
        logger.notice("Автоконвертация слова длиной \(context.word.count)")
        let generation = inputGeneration
        Task { [converter, autoSwitch] in
            guard self.settings.enabled, self.inputGeneration == generation, target.isCurrent() else { return }
            let outcome = await converter.trigger(
                expectedWord: context.word, trailingText: context.trailingText, allowUndo: false
            )
            switch outcome {
            case .converted:
                self.keystrokeBuffer.clear()
            default:
                autoSwitch.clearPendingUndoCandidate()
            }
            self.logger.info("Автоконвертация: \(outcome.label, privacy: .public)")
        }
    }

    private func resetInputContext() {
        inputGeneration &+= 1
        keystrokeBuffer.clear()
        detector = DoubleShiftDetector()
        converter.notifyOtherKeystroke()
        autoSwitch.clearPendingUndoCandidate()
    }

    private func makeConverter() -> Converter {
        Converter(
            layoutManager: layoutManager,
            appRules: appRules,
            undoStore: undoStore,
            frontmostBundleID: { [weak self] in self?.currentFrontmostBundleID() },
            prefersClipboard: { [appProfiles] in appProfiles.prefersClipboard(bundleID: $0) },
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
            onLayoutSwitched: { [weak self] source, target, startedAt in
                self?.eventTap?.recordLayoutChange(from: source, to: target, since: startedAt)
            },
            onConverted: { [weak self] in
                guard let self, self.settings.soundEnabled else { return }
                DispatchQueue.main.async {
                    NSSound(named: NSSound.Name("Tink"))?.play()
                }
            }
        )
    }

    // MARK: - PermGuard

    private func setupPermGuard() {
        permGuard.onPermissionsLost = { [weak self] _ in
            guard let self else { return }
            self.logger.notice("Разрешения потеряны — перехват остановлен")
            DispatchQueue.main.async { self.stopInterception() }
        }
        permGuard.onPermissionsRestored = { [weak self] in
            guard let self else { return }
            self.logger.notice("Разрешения восстановлены — перехват запущен")
            DispatchQueue.main.async { self.startInterception() }
        }
        permGuard.start()
    }

    private func requestPermissionsIfNeeded() {
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
    }

    /// Смена приложения завершает прежний контекст ввода и отмены.
    private func observeWorkspace() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetInputContext() }
        }
    }

    // MARK: - Меню

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "LS"

        let menu = NSMenu()
        menu.delegate = self

        toggleItem = NSMenuItem(title: "", action: #selector(toggleEnabled), keyEquivalent: "e")
        toggleItem.target = self
        menu.addItem(toggleItem)

        permissionsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        permissionsItem.isEnabled = false
        menu.addItem(permissionsItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Выйти из LSwitch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
        updateToggleItem()
        updatePermissionsItem()
    }

    private func updateToggleItem() {
        toggleItem?.title = settings.enabled ? "Выключить LSwitch" : "Включить LSwitch"
        statusItem?.button?.title = settings.enabled ? "LS" : "L̶S̶"
    }

    private func updatePermissionsItem() {
        let status = PermGuard.poll()
        let axMark = status.accessibility ? "✓" : "✗"
        let imMark = status.inputMonitoring ? "✓" : "✗"
        permissionsItem?.title = "Разрешения — Доступ: \(axMark), Мониторинг ввода: \(imMark)"
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, appRules: appRules, personalDictionary: personalDictionary)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Настройки LSwitch"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        // LSUIElement-агент: активируем принудительно, иначе окно не получит фокус.
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updatePermissionsItem()
    }
}

if CommandLine.arguments.contains("--verify-resources") {
    let dictionaries = DictionaryStore()
    let available = dictionaries.contains("привет", language: .russian)
        && dictionaries.contains("hello", language: .english)
    print("resources: \(DictionaryStore.resourceBundle.bundleURL.path)")
    print("dictionaries: \(available ? "ok" : "missing")")
    exit(available ? 0 : 1)
}

if CommandLine.arguments.contains("--probe") {
    Probe.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Агент строки меню: без иконки в Dock.
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
