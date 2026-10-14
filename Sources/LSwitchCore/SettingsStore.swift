import Combine
import Foundation

/// Настройки MVP (spec settings, design D6): UserDefaults + ObservableObject
/// для SwiftUI-окна. Изменения применяются сразу и сохраняются между запусками.
public final class SettingsStore: ObservableObject {

    private enum Key {
        static let enabled = "settings.enabled"
        static let undoWindowSeconds = "settings.undoWindowSeconds"
        static let soundEnabled = "settings.soundEnabled"
        static let launchAtLogin = "settings.launchAtLogin"
    }

    @Published public var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Key.enabled) }
    }

    /// Окно отката после конвертации, секунды (по умолчанию 3 — TZ.md F4).
    @Published public var undoWindowSeconds: Double {
        didSet { defaults.set(undoWindowSeconds, forKey: Key.undoWindowSeconds) }
    }

    @Published public var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Key.soundEnabled) }
    }

    @Published public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.enabled: true,
            Key.undoWindowSeconds: 3.0,
            Key.soundEnabled: true,
            Key.launchAtLogin: false
        ])
        self.enabled = defaults.bool(forKey: Key.enabled)
        self.undoWindowSeconds = defaults.double(forKey: Key.undoWindowSeconds)
        self.soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
    }
}
