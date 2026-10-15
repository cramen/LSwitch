import AppKit
import Foundation

/// Профили приложений: детект тех, у кого AX-запись заведомо сломана.
///
/// Некоторые Electron-обёртки отвечают
/// на `AXUIElementSetAttributeValue` успехом, но вставляют текст у курсора
/// вместо замены диапазона (находка спайка P0.2, Obsidian). Для них
/// AX-попытка портит текст — сразу clipboard-режим. Детект по наличию
/// Electron Framework внутри бандла; результат мемоизируется.
@MainActor
public final class AppProfiles {

    private var cache: [String: Bool] = [:]

    public init() {}

    public func prefersClipboard(bundleID: String) -> Bool {
        // Неподтверждённая модель направляется к отказу clipboard guard до попытки AX-записи.
        if Self.clipboardRejection(bundleID: bundleID) != nil { return true }
        // WebKit может сообщить успех AX-записи без замены, оставив DOM-выделение
        // несогласованным с AX. Для Safari используем нативный Copy/Paste сразу.
        if bundleID == "com.apple.Safari" || bundleID == "com.google.Chrome" { return true }
        if let cached = cache[bundleID] { return cached }
        let detected = detectElectron(bundleID: bundleID)
        cache[bundleID] = detected
        return detected
    }

    /// AXPress меню Chrome принят без эффекта в живой проверке; CGEvent Cmd+C/V работают.
    static func prefersKeyboardCommands(bundleID: String?) -> Bool {
        bundleID == "com.google.Chrome"
    }

    /// Транспорт выбирается до мутации; AX остаётся источником проверяемого снимка.
    static func prefersKeyboardSelection(bundleID: String?) -> Bool {
        bundleID == "com.google.Chrome"
    }

    /// VS Code подтвердил AX-выделение, но Paste дописала результат рядом с исходником.
    static func clipboardRejection(bundleID: String?) -> ConversionDiagnostics.Rejection? {
        bundleID == "com.microsoft.VSCode" ? .unverifiedEditorModel : nil
    }

    private func detectElectron(bundleID: String) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let frameworkURL = appURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: frameworkURL.path)
    }
}
