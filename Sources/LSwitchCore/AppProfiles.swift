import AppKit
import Foundation

/// Профили приложений: детект тех, у кого AX-запись заведомо сломана.
///
/// Electron-обёртки (Obsidian, VS Code, Slack, Discord и др.) отвечают
/// на `AXUIElementSetAttributeValue` успехом, но вставляют текст у курсора
/// вместо замены диапазона (находка спайка P0.2, Obsidian). Для них
/// AX-попытка портит текст — сразу clipboard-режим. Детект по наличию
/// Electron Framework внутри бандла; результат мемоизируется.
@MainActor
public final class AppProfiles {

    private var cache: [String: Bool] = [:]

    public init() {}

    public func prefersClipboard(bundleID: String) -> Bool {
        // WebKit может сообщить успех AX-записи без замены, оставив DOM-выделение
        // несогласованным с AX. Для Safari используем нативный Copy/Paste сразу.
        if bundleID == "com.apple.Safari" { return true }
        if let cached = cache[bundleID] { return cached }
        let detected = detectElectron(bundleID: bundleID)
        cache[bundleID] = detected
        return detected
    }

    private func detectElectron(bundleID: String) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let frameworkURL = appURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: frameworkURL.path)
    }
}
