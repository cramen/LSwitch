import Combine
import Foundation
@testable import LSwitchCore
import XCTest

final class SettingsAutoSwitchTests: XCTestCase {
    private func settings() -> (SettingsStore, UserDefaults) {
        let name = "lswitch.tests.autoswitch.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("Не удалось создать тестовые настройки")
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (SettingsStore(defaults: defaults), defaults)
    }

    func testFreshDefaultsDisableAutoSwitchAndRequireTwoUndos() {
        let (store, _) = settings()
        XCTAssertFalse(store.autoSwitchEnabled)
        XCTAssertEqual(store.undoLearningThreshold, 2)
        XCTAssertEqual(AutoSwitchCoordinator.defaultLearningThreshold, 2)
    }

    func testAutoSwitchAndThresholdSurviveReloadWithoutReplacingSavedChoice() {
        let (store, defaults) = settings()
        store.autoSwitchEnabled = true
        store.undoLearningThreshold = 3
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.autoSwitchEnabled)
        XCTAssertEqual(reloaded.undoLearningThreshold, 3)
        reloaded.autoSwitchEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults).autoSwitchEnabled)
    }

    func testAutoSwitchChangesArePublishedImmediatelyOnSameInstance() {
        let (store, _) = settings()
        var observed: [Bool] = []
        let subscription = store.$autoSwitchEnabled.sink { observed.append($0) }
        store.autoSwitchEnabled = true
        store.autoSwitchEnabled = false
        XCTAssertEqual(observed, [false, true, false])
        withExtendedLifetime(subscription) {}
    }

    func testThresholdClampsOutOfRangeWritesAndPersistsNormalizedValue() {
        let (store, defaults) = settings()
        store.undoLearningThreshold = 0
        XCTAssertEqual(store.undoLearningThreshold, 1)
        XCTAssertEqual(SettingsStore(defaults: defaults).undoLearningThreshold, 1)
        store.undoLearningThreshold = 100
        XCTAssertEqual(store.undoLearningThreshold, 10)
        XCTAssertEqual(SettingsStore(defaults: defaults).undoLearningThreshold, 10)
    }

    func testInvalidSavedThresholdIsNormalizedAtStartup() {
        let (_, defaults) = settings()
        defaults.set(-5, forKey: "settings.undoLearningThreshold")
        XCTAssertEqual(SettingsStore(defaults: defaults).undoLearningThreshold, 1)
        XCTAssertEqual(defaults.integer(forKey: "settings.undoLearningThreshold"), 1)
        defaults.set(900, forKey: "settings.undoLearningThreshold")
        XCTAssertEqual(SettingsStore(defaults: defaults).undoLearningThreshold, 10)
    }

    func testChangingPublishedThresholdChangesExistingCoordinatorImmediately() {
        let (store, defaults) = settings()
        let dictionary = PersonalDictionary(defaults: defaults)
        let coordinator = AutoSwitchCoordinator(
            classifier: WordClassifier(personalDictionary: dictionary), personalDictionary: dictionary
        )
        let subscription = store.$undoLearningThreshold.assign(to: \.learningThreshold, on: coordinator)
        XCTAssertEqual(coordinator.learningThreshold, 2)
        store.undoLearningThreshold = 3
        for _ in 0..<2 {
            XCTAssertEqual(coordinator.evaluate(word: "ghbdtn"), "привет")
            coordinator.registerUndo()
        }
        XCTAssertFalse(dictionary.contains("ghbdtn"))
        XCTAssertEqual(coordinator.learningThreshold, 3)
        XCTAssertEqual(coordinator.evaluate(word: "ghbdtn"), "привет")
        coordinator.registerUndo()
        XCTAssertTrue(dictionary.contains("ghbdtn"))
        XCTAssertNil(coordinator.evaluate(word: "ghbdtn"))
        withExtendedLifetime(subscription) {}
    }

    func testLoweringThresholdAppliesOnNextUndoAndDoesNotLearnWithoutOne() {
        let (store, defaults) = settings()
        let dictionary = PersonalDictionary(defaults: defaults)
        let coordinator = AutoSwitchCoordinator(
            classifier: WordClassifier(personalDictionary: dictionary), personalDictionary: dictionary
        )
        let subscription = store.$undoLearningThreshold.assign(to: \.learningThreshold, on: coordinator)
        store.undoLearningThreshold = 1
        XCTAssertFalse(dictionary.contains("ghbdtn"))
        coordinator.registerUndo()
        XCTAssertFalse(dictionary.contains("ghbdtn"))
        XCTAssertEqual(coordinator.evaluate(word: "ghbdtn"), "привет")
        coordinator.registerUndo()
        XCTAssertTrue(dictionary.contains("ghbdtn"))
        withExtendedLifetime(subscription) {}
    }

    func testChangingThresholdPreservesEarlierUndoCount() {
        let (_, defaults) = settings()
        let dictionary = PersonalDictionary(defaults: defaults)
        let coordinator = AutoSwitchCoordinator(
            classifier: WordClassifier(personalDictionary: dictionary), personalDictionary: dictionary
        )
        XCTAssertNotNil(coordinator.evaluate(word: "ghbdtn"))
        coordinator.registerUndo()
        coordinator.learningThreshold = 3
        XCTAssertNotNil(coordinator.evaluate(word: "ghbdtn"))
        coordinator.registerUndo()
        XCTAssertFalse(dictionary.contains("ghbdtn"))
        XCTAssertNotNil(coordinator.evaluate(word: "ghbdtn"))
        coordinator.registerUndo()
        XCTAssertTrue(dictionary.contains("ghbdtn"))
    }

    func testLearningNotifiesAlreadyObservedDictionary() {
        let (_, defaults) = settings()
        let dictionary = PersonalDictionary(defaults: defaults)
        let coordinator = AutoSwitchCoordinator(
            classifier: WordClassifier(personalDictionary: dictionary), personalDictionary: dictionary
        )
        var changes = 0
        let subscription = dictionary.objectWillChange.sink { changes += 1 }
        for _ in 0..<2 {
            XCTAssertNotNil(coordinator.evaluate(word: "ghbdtn"))
            coordinator.registerUndo()
        }
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(dictionary.words, ["ghbdtn"])
        dictionary.add("GHBDTN")
        XCTAssertEqual(changes, 1)
        dictionary.remove("GHBDTN")
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(dictionary.words.isEmpty)
        withExtendedLifetime(subscription) {}
    }
}
