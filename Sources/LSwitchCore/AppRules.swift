import Foundation

/// Список исключений приложений (spec app-rules, design D4).
///
/// BlockedApps = предустановленный (терминалы) ∪ пользовательский.
/// Пользовательская часть хранится в UserDefaults и редактируется
/// в настройках.
public final class AppRules {

    /// Предустановленные исключения (TZ.md F9): терминалы.
    public static let presetBlockedApps: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2"
    ]

    private static let userDefaultsKey = "appRules.userBlockedApps"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Пользовательская часть blockedApps (bundle ID).
    public var userBlockedApps: [String] {
        get { defaults.stringArray(forKey: Self.userDefaultsKey) ?? [] }
        set { defaults.set(newValue, forKey: Self.userDefaultsKey) }
    }

    public func isBlocked(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return Self.presetBlockedApps.contains(bundleID) || userBlockedApps.contains(bundleID)
    }

    public func addBlockedApp(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !userBlockedApps.contains(trimmed) else { return }
        userBlockedApps.append(trimmed)
    }

    public func removeBlockedApp(_ bundleID: String) {
        userBlockedApps.removeAll { $0 == bundleID }
    }
}
