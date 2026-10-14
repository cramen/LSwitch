import Foundation

/// Частотные словари ru/en (design D1): текстовые ресурсы, ленивая
/// загрузка в `Set<String>`. Источник: hermitdave/FrequencyWords
/// (OpenSubtitles, CC-BY-SA 4.0), см. NOTICE.
public final class DictionaryStore: Sendable {

    public static let shared = DictionaryStore()

    private let ruWords: LockedSet
    private let enWords: LockedSet

    public convenience init() {
        // Bundle.module генерируется SwiftPM как internal — доступен только
        // внутри модуля, поэтому не может быть значением по умолчанию.
        self.init(bundle: Self.resourceBundle)
    }

    /// В .app ресурсы обязаны быть внутри бандла; SwiftPM build-path там не используется.
    public static var resourceBundle: Bundle {
        if Bundle.main.bundleURL.pathExtension == "app" {
            if let resourceURL = Bundle.main.resourceURL,
               let bundle = Bundle(url: resourceURL.appendingPathComponent("LSwitch_LSwitchCore.bundle")) {
                return bundle
            }
            return Bundle.main
        }
        return .module
    }

    public init(bundle: Bundle) {
        self.ruWords = LockedSet(bundle: bundle, resource: "ru.words")
        self.enWords = LockedSet(bundle: bundle, resource: "en.words")
    }

    public func contains(_ word: String, language: Layout) -> Bool {
        let normalized = word.lowercased()
        switch language {
        case .russian: return ruWords.contains(normalized)
        case .english: return enWords.contains(normalized)
        }
    }

    /// Ленивое множество слов: ресурс читается при первом обращении.
    private final class LockedSet: @unchecked Sendable {
        private let bundle: Bundle
        private let resource: String
        private let lock = NSLock()
        private var words: Set<String>?

        init(bundle: Bundle, resource: String) {
            self.bundle = bundle
            self.resource = resource
        }

        func contains(_ word: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if words == nil { words = load() }
            return words?.contains(word) ?? false
        }

        private func load() -> Set<String> {
            guard let url = bundle.url(forResource: resource, withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return []
            }
            return Set(text.split(separator: "\n").map { String($0) })
        }
    }
}
