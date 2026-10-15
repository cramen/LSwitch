import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

final class DictionaryPreparationTests: XCTestCase {
    func testPrewarmLoadsBothLanguagesOnceAndIsIdempotent() {
        let loads = LoadCounter()
        let store = DictionaryStore(load: loads.load)
        XCTAssertFalse(store.isPrepared)
        XCTAssertEqual(loads.count(for: .russian), 0)
        XCTAssertEqual(loads.count(for: .english), 0)
        let prepared = store.prewarm()
        XCTAssertEqual(prepared.russianWords, 1)
        XCTAssertEqual(prepared.englishWords, 1)
        XCTAssertTrue(prepared.isReady)
        XCTAssertTrue(store.isPrepared)
        XCTAssertEqual(store.prewarm(), prepared)
        XCTAssertTrue(store.contains("ПРИВЕТ", language: .russian))
        XCTAssertTrue(store.contains("HELLO", language: .english))
        XCTAssertEqual(loads.count(for: .russian), 1)
        XCTAssertEqual(loads.count(for: .english), 1)
    }

    func testFirstVerdictsAfterPrewarmDoNotReadAnyResources() throws {
        let loads = LoadCounter()
        let store = DictionaryStore(load: loads.load)
        let classifier = WordClassifier(dictionaries: store, personalDictionary: try dictionary())
        XCTAssertTrue(store.prewarm().isReady)
        XCTAssertEqual(classifier.verdict(for: "ghbdtn"), .wrongLayout(converted: "привет"))
        XCTAssertEqual(classifier.verdict(for: "руддщ"), .wrongLayout(converted: "hello"))
        XCTAssertEqual(classifier.verdict(for: "hello"), .correct)
        XCTAssertEqual(classifier.verdict(for: "unknown"), .correct)
        XCTAssertEqual(loads.count(for: .russian), 1)
        XCTAssertEqual(loads.count(for: .english), 1)
    }

    func testPrewarmDoesNotChangeClassificationOrHeuristics() throws {
        let coldLoads = LoadCounter()
        let warmLoads = LoadCounter()
        let cold = WordClassifier(dictionaries: DictionaryStore(load: coldLoads.load),
                                  personalDictionary: try dictionary())
        let warmedStore = DictionaryStore(load: warmLoads.load)
        warmedStore.prewarm()
        let warm = WordClassifier(dictionaries: warmedStore, personalDictionary: try dictionary())
        for word in ["ghbdtn", "руддщ", "hello", "привет", "GHBDTN", "ghBdtn", "code123", "rf;tncz"] {
            XCTAssertEqual(warm.verdict(for: word), cold.verdict(for: word))
        }
        XCTAssertEqual(coldLoads.count(for: .russian), 1)
        XCTAssertEqual(coldLoads.count(for: .english), 1)
    }

    func testMissingResourceDoesNotReportReadyOrRepeatIO() {
        var loads = 0
        let store = DictionaryStore(load: { language in
            loads += 1
            return language == .english ? ["hello"] : []
        })
        let prepared = store.prewarm()
        XCTAssertFalse(prepared.isReady)
        XCTAssertFalse(store.isPrepared)
        XCTAssertEqual(prepared.russianWords, 0)
        XCTAssertEqual(prepared.englishWords, 1)
        XCTAssertFalse(store.contains("привет", language: .russian))
        XCTAssertTrue(store.contains("hello", language: .english))
        XCTAssertEqual(store.prewarm(), prepared)
        XCTAssertEqual(loads, 2)
    }

    func testConcurrentPreparationAndLookupsStillLoadEachLanguageOnce() {
        let loads = LoadCounter()
        let store = DictionaryStore(load: loads.load)
        DispatchQueue.concurrentPerform(iterations: 20) { iteration in
            if iteration.isMultiple(of: 2) {
                XCTAssertTrue(store.prewarm().isReady)
            } else {
                XCTAssertTrue(store.contains("привет", language: .russian))
                XCTAssertTrue(store.contains("hello", language: .english))
            }
        }
        XCTAssertEqual(loads.count(for: .russian), 1)
        XCTAssertEqual(loads.count(for: .english), 1)
    }

    private func dictionary() throws -> PersonalDictionary {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "lswitch.prewarm.\(UUID().uuidString)"))
        return PersonalDictionary(defaults: defaults)
    }
}

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Layout: Int] = [:]

    func load(_ language: Layout) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        counts[language, default: 0] += 1
        return language == .russian ? ["привет"] : ["hello"]
    }

    func count(for language: Layout) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[language, default: 0]
    }
}
