import Combine
import Foundation

public enum LocalAppMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case builtIn, accessibility, keyboardClipboard, disabled
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .builtIn: return "Встроенный профиль"
        case .accessibility: return "Только Accessibility"
        case .keyboardClipboard: return "Клавиатура + буфер обмена"
        case .disabled: return "Выключено для приложения"
        }
    }
}

/// Только настройки маршрута по точному ID; никаких данных редактора или clipboard.
@MainActor
public final class LocalAppProfiles: ObservableObject {
    private struct Document: Codable {
        let version: Int
        let profiles: [String: String]
    }
    private static let key = "settings.localAppProfiles.v1"
    private let defaults: UserDefaults
    @Published public private(set) var profiles: [String: LocalAppMode]
    public private(set) var revision: UInt64 = 0

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), data.count <= 131_072,
           let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1,
           document.profiles.count <= 128 {
            profiles = document.profiles.reduce(into: [:]) { result, entry in
                if Self.validBundleID(entry.key), let mode = LocalAppMode(rawValue: entry.value), mode != .builtIn {
                    result[entry.key] = mode
                }
            }
        } else { profiles = [:] }
    }

    public func mode(for bundleID: String?) -> LocalAppMode {
        guard let bundleID else { return .builtIn }
        return profiles[bundleID] ?? .builtIn
    }

    @discardableResult
    public func set(_ mode: LocalAppMode, for bundleID: String) -> Bool {
        let bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validBundleID(bundleID), profiles.count < 128 || profiles[bundleID] != nil || mode == .builtIn else {
            return false
        }
        guard self.mode(for: bundleID) != mode else { return true }
        var updated = profiles
        updated[bundleID] = mode == .builtIn ? nil : mode
        let document = Document(version: 1, profiles: updated.mapValues(\.rawValue))
        guard let data = try? JSONEncoder().encode(document) else { return false }
        defaults.set(data, forKey: Self.key)
        revision &+= 1
        profiles = updated
        return true
    }

    public static func validBundleID(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return value.utf8.count <= 255 && parts.count >= 2 && parts.allSatisfy {
            !$0.isEmpty && $0.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}
