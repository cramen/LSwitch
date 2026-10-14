@testable import LSwitchCore
import XCTest

private func freshDefaults() -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: "lswitch.tests.\(UUID().uuidString)") else {
        fatalError("Не удалось создать тестовый UserDefaults")
    }
    return defaults
}

final class WordClassifierTests: XCTestCase {

    private func makeClassifier(
        defaults: UserDefaults? = nil
    ) -> WordClassifier {
        let suite = defaults ?? freshDefaults()
        return WordClassifier(personalDictionary: PersonalDictionary(defaults: suite))
    }

    func testEnglishTypedInsteadOfRussian() {
        XCTAssertEqual(makeClassifier().verdict(for: "ghbdtn"), .wrongLayout(converted: "привет"))
    }

    func testRussianTypedInsteadOfEnglish() {
        XCTAssertEqual(makeClassifier().verdict(for: "руддщ"), .wrongLayout(converted: "hello"))
    }

    func testCorrectWordsAreNotTouched() {
        XCTAssertEqual(makeClassifier().verdict(for: "привет"), .correct)
        XCTAssertEqual(makeClassifier().verdict(for: "hello"), .correct)
    }

    func testUnknownWordIsNotTouched() {
        XCTAssertEqual(makeClassifier().verdict(for: "qwertz"), .correct)
        XCTAssertEqual(makeClassifier().verdict(for: "йцуке"), .correct)
    }

    func testShortWordsBlocked() {
        XCTAssertEqual(makeClassifier().verdict(for: "щя"), .blockedByHeuristics)
        XCTAssertEqual(makeClassifier().verdict(for: "z"), .blockedByHeuristics)
    }

    func testPasswordLikeBlocked() {
        XCTAssertEqual(makeClassifier().verdict(for: "QwErTy1"), .blockedByHeuristics)
        XCTAssertEqual(makeClassifier().verdict(for: "ghBdtn"), .blockedByHeuristics)
    }

    func testAllCapsAllowed() {
        // Полностью верхний регистр — не «пароль-подобный», конвертируем.
        XCTAssertEqual(makeClassifier().verdict(for: "GHBDTN"), .wrongLayout(converted: "ПРИВЕТ"))
    }

    func testLayoutPunctuationConverts() {
        // «;» → «ж»: rf;tncz = «кажется».
        XCTAssertEqual(makeClassifier().verdict(for: "rf;tncz"), .wrongLayout(converted: "кажется"))
    }

    func testPersonalDictionaryExcludes() {
        let suite = freshDefaults()
        let personal = PersonalDictionary(defaults: suite)
        personal.add("ghbdtn")
        XCTAssertEqual(makeClassifier(defaults: suite).verdict(for: "ghbdtn"), .blockedByHeuristics)
    }

    func testOmographUntouched() {
        // Слово, словарное на языке набора, конвертировать нельзя,
        // даже если invert попадает в другой словарь.
        let classifier = makeClassifier()
        if case .wrongLayout(let converted) = classifier.verdict(for: "hell") {
            XCTFail("омограф конвертирован: \(converted)")
        }
    }
}

final class HeuristicsTests: XCTestCase {

    func testMinimumLength() {
        XCTAssertFalse(WordClassifier.passesHeuristics("ab"))
        XCTAssertTrue(WordClassifier.passesHeuristics("abc"))
    }

    func testDigitsRejected() {
        XCTAssertFalse(WordClassifier.passesHeuristics("abc1"))
    }

    func testMixedCaseRejected() {
        XCTAssertFalse(WordClassifier.passesHeuristics("aBc"))
        XCTAssertTrue(WordClassifier.passesHeuristics("abc"))
        XCTAssertTrue(WordClassifier.passesHeuristics("ABC"))
    }

    func testPunctuationRejected() {
        XCTAssertFalse(WordClassifier.passesHeuristics("abc!"))
        XCTAssertFalse(WordClassifier.passesHeuristics("word-word"))
    }

    func testLayoutPunctuationAllowed() {
        // «;» на клавише «ж», «'» — «э»: слова с ними конвертируются.
        XCTAssertTrue(WordClassifier.passesHeuristics("rf;tncz"))
    }
}

final class AutoSwitchCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> (AutoSwitchCoordinator, PersonalDictionary) {
        let suite = freshDefaults()
        let personal = PersonalDictionary(defaults: suite)
        let coordinator = AutoSwitchCoordinator(
            classifier: WordClassifier(personalDictionary: personal),
            personalDictionary: personal
        )
        return (coordinator, personal)
    }

    func testEvaluateReturnsConverted() {
        let (coordinator, _) = makeCoordinator()
        XCTAssertEqual(coordinator.evaluate(word: "ghbdtn"), "привет")
        XCTAssertEqual(coordinator.evaluate(word: "hello"), nil)
    }

    func testTwoUndosTeachDictionary() {
        let (coordinator, personal) = makeCoordinator()
        _ = coordinator.evaluate(word: "ghbdtn")
        coordinator.registerUndo()
        XCTAssertFalse(personal.contains("ghbdtn"))

        _ = coordinator.evaluate(word: "ghbdtn")
        coordinator.registerUndo()
        XCTAssertTrue(personal.contains("ghbdtn"))
        // Третья попытка: слово уже исключено.
        XCTAssertNil(coordinator.evaluate(word: "ghbdtn"))
    }

    func testUndoWithoutPendingAutoConversionIsNoop() {
        let (coordinator, personal) = makeCoordinator()
        coordinator.registerUndo()
        coordinator.registerUndo()
        XCTAssertTrue(personal.words.isEmpty)
    }

    func testClearCandidateResetsLearning() {
        let (coordinator, personal) = makeCoordinator()
        _ = coordinator.evaluate(word: "ghbdtn")
        coordinator.clearPendingUndoCandidate()
        coordinator.registerUndo()
        XCTAssertFalse(personal.contains("ghbdtn"))
    }
}

final class PersonalDictionaryTests: XCTestCase {

    private func makeDictionary() -> (PersonalDictionary, UserDefaults) {
        let suite = freshDefaults()
        return (PersonalDictionary(defaults: suite), suite)
    }

    func testAddContainsCaseInsensitive() {
        let (personal, _) = makeDictionary()
        personal.add("Volkswagen")
        XCTAssertTrue(personal.contains("volkswagen"))
        XCTAssertTrue(personal.contains("VOLKSWAGEN"))
    }

    func testDuplicatesIgnored() {
        let (personal, _) = makeDictionary()
        personal.add("слово")
        personal.add("СЛОВО")
        XCTAssertEqual(personal.words.count, 1)
    }

    func testPersistenceAcrossInstances() {
        let (personal, suite) = makeDictionary()
        personal.add("хабр")
        XCTAssertTrue(PersonalDictionary(defaults: suite).contains("хабр"))
    }

    func testRemove() {
        let (personal, _) = makeDictionary()
        personal.add("test")
        personal.remove("TEST")
        XCTAssertFalse(personal.contains("test"))
    }
}

final class LastWordBeforeDelimiterTests: XCTestCase {

    func testTrailingDelimiterSkipped() {
        let buffer = KeystrokeBuffer(capacity: 100)
        for letter in "ghbdtn " {
            let kind: Keystroke.Kind = letter == " " ? .delimiter(" ") : .character(letter)
            buffer.append(Keystroke(kind: kind))
        }
        XCTAssertEqual(buffer.lastWordBeforeDelimiter(), "ghbdtn")
        // Обычный lastWord при этом пуст — разделитель в конце.
        XCTAssertEqual(buffer.lastWord(), "")
    }

    func testEmptyAfterControl() {
        let buffer = KeystrokeBuffer(capacity: 100)
        buffer.append(Keystroke(kind: .character("a")))
        buffer.append(Keystroke(kind: .control))
        XCTAssertEqual(buffer.lastWordBeforeDelimiter(), "")
    }
}
