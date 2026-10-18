import AppKit
import SwiftUI

extension AppDelegate {
    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, appRules: appRules, personalDictionary: personalDictionary,
                                    hotkeys: hotkeySettings)
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
