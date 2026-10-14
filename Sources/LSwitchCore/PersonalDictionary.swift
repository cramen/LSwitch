import Foundation

/// Персональный словарь слов-исключений (spec personal-dictionary).
///
/// Персистентен (UserDefaults), сравнение без учёта регистра. Пополняется
/// обучением на отменах (design D4) и вручную в настройках.
public final class PersonalDictionary {

    private static let userDefaultsKey = "personalDictionary.words"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var words: [String] {
        defaults.stringArray(forKey: Self.userDefaultsKey) ?? []
    }

    public func contains(_ word: String) -> Bool {
        let needle = word.lowercased()
        return words.contains { $0.lowercased() == needle }
    }

    public func add(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !contains(trimmed) else { return }
        defaults.set(words + [trimmed], forKey: Self.userDefaultsKey)
    }

    public func remove(_ word: String) {
        let needle = word.lowercased()
        defaults.set(words.filter { $0.lowercased() != needle }, forKey: Self.userDefaultsKey)
    }
}
