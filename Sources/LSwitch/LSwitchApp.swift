import AppKit
import LSwitchCore

/// Точка входа menu-bar агента LSwitch.
///
/// На этапе инициализации это каркас: статус-меню, включение/выключение,
/// заглушка настроек. Перехват клавиатуры (CGEventTap) и конвертер
/// подключаются в этапе 1 по TZ.md.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var isEnabled = true {
        didSet { updateToggleItem() }
    }
    private var toggleItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "LS"

        let menu = NSMenu()

        toggleItem = NSMenuItem(
            title: "",
            action: #selector(toggleEnabled),
            keyEquivalent: "e"
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Настройки…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
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
    }

    private func updateToggleItem() {
        toggleItem?.title = isEnabled ? "Выключить LSwitch" : "Включить LSwitch"
        statusItem?.button?.title = isEnabled ? "LS" : "L̶S̶"
    }

    @objc private func toggleEnabled() {
        isEnabled.toggle()
    }

    @objc private func openSettings() {
        // TODO(этап 1.5): SwiftUI-окно настроек
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Агент строки меню: без иконки в Dock.
app.setActivationPolicy(.accessory)
app.run()
