import AppKit
import Foundation

/// Профили приложений: детект тех, у кого AX-запись заведомо сломана.
///
/// Electron-обёртки (Obsidian, VS Code, Slack, Discord и др.) отвечают
/// на `AXUIElementSetAttributeValue` успехом, но вставляют текст у курсора
/// вместо замены диапазона (находка спайка P0.2, Obsidian). Для них
/// AX-попытка портит текст — сразу clipboard-режим. Детект по наличию
/// Electron Framework внутри бандла; результат мемоизируется.
public final class AppProfiles: @unchecked Sendable {

    private let lock = NSLock()
    private var cache: [String: Bool] = [:]

    public init() {}

    public func prefersClipboard(bundleID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
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
