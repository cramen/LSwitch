import Combine
import Foundation

/// Настройки MVP (spec settings, design D6): UserDefaults + ObservableObject
/// для SwiftUI-окна. Изменения применяются сразу и сохраняются между запусками.
public final class SettingsStore: ObservableObject {

    private enum Key {
        static let conversionHotkey = "settings.conversionHotkey"
        static let enabled = "settings.enabled"
        static let undoWindowSeconds = "settings.undoWindowSeconds"
        static let soundEnabled = "settings.soundEnabled"
        static let launchAtLogin = "settings.launchAtLogin"
        static let autoSwitchEnabled = "settings.autoSwitchEnabled"
        static let undoLearningThreshold = "settings.undoLearningThreshold"
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

    /// Автопереключение по словарному классификатору. По умолчанию выключено
    /// (консервативный старт, TZ.md R6); ручная конвертация работает всегда.
    @Published public var autoSwitchEnabled: Bool {
        didSet { defaults.set(autoSwitchEnabled, forKey: Key.autoSwitchEnabled) }
    }

    /// Число отмен до добавления слова в исключения. UI и сохранённые значения используют один диапазон.
    @Published public var undoLearningThreshold: Int {
        didSet {
            let normalized = AutoSwitchCoordinator.normalizedLearningThreshold(undoLearningThreshold)
            if undoLearningThreshold != normalized { undoLearningThreshold = normalized }
            defaults.set(normalized, forKey: Key.undoLearningThreshold)
        }
    }

    @Published public var conversionHotkey: ConversionHotkey {
        didSet {
            if !conversionHotkey.isValid { conversionHotkey = .doubleShift }
            defaults.set(try? JSONEncoder().encode(conversionHotkey), forKey: Key.conversionHotkey)
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.enabled: true,
            Key.undoWindowSeconds: 3.0,
            Key.soundEnabled: true,
            Key.launchAtLogin: false,
            Key.autoSwitchEnabled: false,
            Key.undoLearningThreshold: AutoSwitchCoordinator.defaultLearningThreshold
        ])
        let saved = defaults.data(forKey: Key.conversionHotkey)
            .flatMap { try? JSONDecoder().decode(ConversionHotkey.self, from: $0) }
        conversionHotkey = saved?.isValid == true ? (saved ?? .doubleShift) : .doubleShift
        self.enabled = defaults.bool(forKey: Key.enabled)
        self.undoWindowSeconds = defaults.double(forKey: Key.undoWindowSeconds)
        self.soundEnabled = defaults.bool(forKey: Key.soundEnabled)
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        self.autoSwitchEnabled = defaults.bool(forKey: Key.autoSwitchEnabled)
        self.undoLearningThreshold = AutoSwitchCoordinator.normalizedLearningThreshold(
            defaults.integer(forKey: Key.undoLearningThreshold)
        )
        defaults.set(undoLearningThreshold, forKey: Key.undoLearningThreshold)
    }
}
