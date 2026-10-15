import Dispatch
import Foundation
import os

/// Частотные словари ru/en (design D1): текстовые ресурсы, ленивая
/// загрузка в `Set<String>`. Источник: hermitdave/FrequencyWords
/// (OpenSubtitles, CC-BY-SA 4.0), см. NOTICE.
public final class DictionaryStore: Sendable {

    public static let shared = DictionaryStore()
    private static let logger = Logger(subsystem: "LSwitch", category: "Classification")

    public struct Preparation: Equatable, Sendable {
        public let russianWords: Int
        public let englishWords: Int
        public var isReady: Bool { russianWords > 0 && englishWords > 0 }
    }

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
        self.ruWords = LockedSet(language: .russian) { Self.loadWords(bundle: bundle, resource: "ru.words") }
        self.enWords = LockedSet(language: .english) { Self.loadWords(bundle: bundle, resource: "en.words") }
    }

    /// Подмена чтения позволяет доказать отсутствие I/O при первом verdict после подготовки.
    init(load: @escaping (Layout) -> Set<String>) {
        self.ruWords = LockedSet(language: .russian) { load(.russian) }
        self.enWords = LockedSet(language: .english) { load(.english) }
    }

    public var isPrepared: Bool {
        (ruWords.loadedCount ?? 0) > 0 && (enWords.loadedCount ?? 0) > 0
    }

    /// Приложение вызывает до запуска tap; повторный вызов не перечитывает ресурсы.
    @discardableResult
    public func prewarm() -> Preparation {
        let started = DispatchTime.now().uptimeNanoseconds
        let reused = isPrepared
        let result = Preparation(russianWords: ruWords.prepare(), englishWords: enWords.prepare())
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        let ready = result.isReady
        Self.logger.notice("classification phase=prewarm elapsed_ns=\(elapsed, privacy: .public)")
        Self.logger.notice("classification prepared=\(ready, privacy: .public) reused=\(reused, privacy: .public)")
        return result
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
        private let language: Layout
        private let load: () -> Set<String>
        private let lock = NSLock()
        private var words: Set<String>?

        init(language: Layout, load: @escaping () -> Set<String>) {
            self.language = language
            self.load = load
        }

        var loadedCount: Int? {
            lock.lock()
            defer { lock.unlock() }
            return words?.count
        }

        func prepare() -> Int {
            lock.lock()
            defer { lock.unlock() }
            loadIfNeeded()
            return words?.count ?? 0
        }

        func contains(_ word: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            loadIfNeeded()
            return words?.contains(word) ?? false
        }

        private func loadIfNeeded() {
            guard words == nil else { return }
            let started = DispatchTime.now().uptimeNanoseconds
            let language = self.language.rawValue
            DictionaryStore.logger.notice("classification phase=loadBegin language=\(language, privacy: .public)")
            words = load()
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            let count = words?.count ?? 0
            DictionaryStore.logger.notice("classification phase=loadEnd elapsed_ns=\(elapsed, privacy: .public)")
            DictionaryStore.logger.notice("classification language=\(language, privacy: .public) entries=\(count)")
        }
    }

    private static func loadWords(bundle: Bundle, resource: String) -> Set<String> {
        guard let url = bundle.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { String($0) })
    }
}
