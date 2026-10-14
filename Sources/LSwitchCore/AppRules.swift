import Foundation

/// Список исключений приложений (spec app-rules, design D4).
///
/// Blacklist = предустановленный (терминалы) ∪ пользовательский.
/// Пользовательская часть хранится в UserDefaults и редактируется
/// в настройках.
public final class AppRules {

    /// Предустановленные исключения (TZ.md F9): терминалы.
    public static let presetBlacklist: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2"
    ]

    private static let userDefaultsKey = "appRules.userBlacklist"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Пользовательская часть blacklist (bundle ID).
    public var userBlacklist: [String] {
        get { defaults.stringArray(forKey: Self.userDefaultsKey) ?? [] }
        set { defaults.set(newValue, forKey: Self.userDefaultsKey) }
    }

    public func isBlocked(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return Self.presetBlacklist.contains(bundleID) || userBlacklist.contains(bundleID)
    }

    public func addToBlacklist(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !userBlacklist.contains(trimmed) else { return }
        userBlacklist.append(trimmed)
    }

    public func removeFromBlacklist(_ bundleID: String) {
        userBlacklist.removeAll { $0 == bundleID }
    }
}
