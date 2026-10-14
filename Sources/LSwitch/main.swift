import AppKit
import LSwitchCore
import os

/// Точка входа menu-bar агента LSwitch.
///
/// На этапе 0 (спайки) помимо каркаса статус-меню содержит экспериментальные
/// пункты «Спайк: …»: перехват клавиатуры (P0.1), AX-конвертация (P0.2),
/// конвертация через буфер (P0.3). В этапе 1 пункты спайков заменяются
/// продуктовой логикой.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var isEnabled = true {
        didSet { updateToggleItem() }
    }
    private var toggleItem: NSMenuItem!
    private var spikeTapItem: NSMenuItem!

    // MARK: - Спайки

    private let logger = Logger(subsystem: "LSwitch", category: "Spike")
    private let keystrokeBuffer = KeystrokeBuffer()
    private let classifier = KeystrokeClassifier()
    private var eventTap: EventTapCore?
    private let statsLock = NSLock()
    private var interceptedCount = 0
    private var syntheticCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "LS"

        let menu = NSMenu()
        addToggleItem(to: menu)
        menu.addItem(.separator())
        addSpikeItems(to: menu)
        menu.addItem(.separator())
        addUtilityItems(to: menu)

        statusItem.menu = menu
        updateToggleItem()
    }

    private func addToggleItem(to menu: NSMenu) {
        toggleItem = NSMenuItem(
            title: "",
            action: #selector(toggleEnabled),
            keyEquivalent: "e"
        )
        toggleItem.target = self
        menu.addItem(toggleItem)
    }

    private func addSpikeItems(to menu: NSMenu) {
        menu.addItem(makeInfoItem("— Спайки (этап 0) —"))
        spikeTapItem = makeActionItem(
            title: "Спайк: перехват клавиатуры", action: #selector(toggleSpikeTap), key: "t"
        )
        menu.addItem(spikeTapItem)
        menu.addItem(makeActionItem(
            title: "Спайк: конвертация через AX", action: #selector(runAXConversion), key: "a"
        ))
        menu.addItem(makeActionItem(
            title: "Спайк: конвертация через буфер", action: #selector(runClipboardConversion), key: "c"
        ))
        menu.addItem(makeActionItem(
            title: "Статус спайков…", action: #selector(showSpikeStats), key: "i"
        ))
    }

    private func addUtilityItems(to menu: NSMenu) {
        menu.addItem(makeActionItem(
            title: "Настройки…", action: #selector(openSettings), key: ","
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Выйти из LSwitch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }

    private func makeActionItem(title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func makeInfoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func updateToggleItem() {
        toggleItem?.title = isEnabled ? "Выключить LSwitch" : "Включить LSwitch"
        statusItem?.button?.title = isEnabled ? "LS" : "L̶S̶"
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
    }

    // MARK: - Спайк P0.1: перехват

    @objc private func toggleSpikeTap() {
        if let eventTap {
            eventTap.stop()
            self.eventTap = nil
            spikeTapItem.state = .off
            logger.info("Перехват остановлен")
            return
        }

        let tap = EventTapCore { [weak self] raw in
            self?.handleIntercepted(raw)
        }
        guard tap.start() else {
            showAlert(
                title: "Не удалось запустить перехват",
                text: "Проверьте разрешения Accessibility и Input Monitoring "
                    + "в Системных настройках → Конфиденциальность."
            )
            promptForAccessibility()
            return
        }
        eventTap = tap
        spikeTapItem.state = .on
        logger.info("Перехват запущен")
    }

    /// Вызывается на очереди обработки EventTapCore.
    private func handleIntercepted(_ raw: RawKeyEvent) {
        statsLock.lock()
        interceptedCount += 1
        if raw.isSynthetic { syntheticCount += 1 }
        let intercepted = interceptedCount
        let synthetic = syntheticCount
        statsLock.unlock()

        logger.debug(
            "key \(raw.keyCode) '\(raw.characters)' synth=\(raw.isSynthetic) [\(intercepted)/\(synthetic)]"
        )
        if let kind = classifier.classify(raw) {
            keystrokeBuffer.append(Keystroke(kind: kind, isSynthetic: raw.isSynthetic))
        }
    }

    // MARK: - Спайк P0.2: AX-конвертация

    @objc private func runAXConversion() {
        let converter = AXTextConverter()
        switch converter.convert() {
        case .success(let outcome):
            logger.info("AX: \(outcome.original) → \(outcome.converted) (selection=\(outcome.wasSelection))")
        case .failure(let error):
            logger.notice("AX-конвертация не выполнена: \(String(describing: error))")
            showAlert(title: "AX-конвертация", text: "Не выполнена: \(error)")
            if error == .noFocusedElement { promptForAccessibility() }
        }
    }

    // MARK: - Спайк P0.3: clipboard-конвертация

    @objc private func runClipboardConversion() {
        let converter = ClipboardConverter()
        Task {
            let outcome = await converter.convertSelection()
            switch outcome {
            case .success(let original, let converted):
                logger.info("Clipboard: \(original) → \(converted)")
            case .copyFailed:
                logger.notice("Clipboard: Cmd+C не дал результата")
            }
        }
    }

    // MARK: - Диагностика

    @objc private func showSpikeStats() {
        statsLock.lock()
        let intercepted = interceptedCount
        let synthetic = syntheticCount
        statsLock.unlock()

        let axTrusted = AXIsProcessTrusted()
        let listenAccess = CGPreflightListenEventAccess()
        let tapState: String
        switch eventTap?.state {
        case .running: tapState = "работает"
        case .recovering: tapState = "восстановление"
        case .stopped, nil: tapState = "остановлен"
        }

        showAlert(
            title: "Статус спайков",
            text: """
            Разрешение Accessibility: \(axTrusted ? "есть" : "НЕТ")
            Разрешение Input Monitoring: \(listenAccess ? "есть" : "НЕТ")
            Event tap: \(tapState), пересозданий: \(eventTap?.recoveryCount ?? 0)
            Перехвачено событий: \(intercepted), из них синтетических: \(synthetic)
            Последнее слово в буфере: «\(keystrokeBuffer.lastWord())»
            """
        )
    }

    private func promptForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
    }

    private func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    @objc private func openSettings() {
        // Заглушка до этапа 1.5: SwiftUI-окно настроек.
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
