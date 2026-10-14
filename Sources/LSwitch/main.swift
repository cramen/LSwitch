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
    private var detector = DoubleShiftDetector()
    private var eventTap: EventTapCore?
    private lazy var converter = makeConverter()

    private var workspaceObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    /// Активное приложение — кэш, обновляемый на главном потоке по
    /// нотификации NSWorkspace (сам NSWorkspace дёргать с фоновых очередей
    /// нельзя, а перехват работает на своей).
    private let frontmostLock = NSLock()
    private var frontmostAppBundleID: String?

    private func currentFrontmostBundleID() -> String? {
        frontmostLock.lock()
        defer { frontmostLock.unlock() }
        return frontmostAppBundleID
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
        logger.info("TIS источники: \(self.layoutManager.enabledSourceIDs())")
    }

    // MARK: - Перехват → детект → конвертация

    private func startInterception() {
        guard eventTap == nil, settings.enabled else { return }
        let tap = EventTapCore { [weak self] raw in
            self?.handleIntercepted(raw)
        }
        guard tap.start() else {
            logger.error("Event tap не запущен — нет разрешений?")
            return
        }
        eventTap = tap
    }

    private func stopInterception() {
        eventTap?.stop()
        eventTap = nil
    }

    /// Вызывается на очереди обработки EventTapCore.
    private func handleIntercepted(_ raw: RawKeyEvent) {
        if appRules.isBlocked(bundleID: currentFrontmostBundleID()) {
            keystrokeBuffer.clear()
            return
        }
        if detector.handle(raw) {
            Task { [converter, autoSwitch] in
                let outcome = await converter.trigger()
                if case .undone = outcome {
                    // Откат автоконвертации — сигнал обучения (design D4).
                    autoSwitch.registerUndo()
                } else if case .converted = outcome {
                    autoSwitch.clearPendingUndoCandidate()
                    self.keystrokeBuffer.removeLastWord()
                }
                self.logger.info("Хоткей: \(String(describing: outcome))")
            }
            return
        }
        if raw.type == .keyDown, !raw.isSynthetic {
            converter.notifyOtherKeystroke()
        }
        if let kind = classifier.classify(raw) {
            keystrokeBuffer.append(Keystroke(kind: kind, isSynthetic: raw.isSynthetic))
            if case .delimiter = kind, settings.autoSwitchEnabled {
                maybeAutoConvert()
            }
        }
    }

    /// Автопереключение: разделитель набран, проверяем последнее слово.
    /// Вызывается на очереди обработки EventTapCore.
    private func maybeAutoConvert() {
        let word = keystrokeBuffer.lastWordBeforeDelimiter()
        guard autoSwitch.evaluate(word: word) != nil else { return }
        logger.notice("Автоконвертация слова длиной \(word.count)")
        Task { [converter, autoSwitch] in
            let outcome = await converter.trigger(allowUndo: false)
            switch outcome {
            case .converted:
                self.keystrokeBuffer.removeLastWord()
            case .failed:
                autoSwitch.clearPendingUndoCandidate()
            default:
                break
            }
            self.logger.info("Автоконвертация: \(String(describing: outcome))")
        }
    }

    private func makeConverter() -> Converter {
        Converter(
            layoutManager: layoutManager,
            appRules: appRules,
            undoStore: undoStore,
            frontmostBundleID: { [weak self] in self?.currentFrontmostBundleID() },
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

    /// Смена активного приложения очищает буфер ввода (spec app-rules)
    /// и обновляет кэш frontmost (нотификация приходит на главном потоке).
    private func observeWorkspace() {
        frontmostLock.lock()
        frontmostAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        frontmostLock.unlock()
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let bundleID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            self.frontmostLock.lock()
            self.frontmostAppBundleID = bundleID
            self.frontmostLock.unlock()
            self.keystrokeBuffer.clear()
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
        if settings.enabled {
            startInterception()
        } else {
            stopInterception()
        }
        updateToggleItem()
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

if CommandLine.arguments.contains("--probe") {
    Probe.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Агент строки меню: без иконки в Dock.
app.setActivationPolicy(.accessory)
app.run()
