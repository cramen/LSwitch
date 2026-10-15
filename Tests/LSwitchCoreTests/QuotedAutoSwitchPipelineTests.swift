import Foundation
@testable import LSwitchCore
import XCTest

final class QuotedAutoSwitchPipelineTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        suites.removeAll()
        super.tearDown()
    }

    @MainActor
    func testOpeningAndClosingQuotesSurviveTheCompleteCandidatePipeline() throws {
        let fixtures: [(SourceLanguage, String, String)] = [
            (.swift, "let message = \"ghbdtn ", "let message = \"привет "),
            (.swift, "let message = \"ghbdtn\", ", "let message = \"привет\", "),
            (.javascript, "const message = \"ghbdtn ", "const message = \"привет "),
            (.python, "message = 'ghbdtn' ", "message = 'привет' "),
            (.swift, "let message = \"\"\"ghbdtn ", "let message = \"\"\"привет "),
            (.python, "message = '''ghbdtn ", "message = '''привет ")
        ]
        for (language, input, expected) in fixtures {
            let pipeline = try pipeline(input)
            XCTAssertEqual(pipeline.candidate.word, "ghbdtn")
            XCTAssertTrue(pipeline.request.permitsAutomaticContext(source(input, language), plan: pipeline.plan))
            XCTAssertEqual(pipeline.plan.resultingText, expected)
        }
    }

    @MainActor
    func testLeadingLayoutPunctuationWinsBeforeQuoteFallback() throws {
        for (input, expected) in [("'nj ", "это "), ("`krf ", "ёлка "), ("rf;tncz ", "кажется ")] {
            let pipeline = try pipeline(input)
            XCTAssertEqual(pipeline.candidate.word, try context(input).word)
            XCTAssertEqual(pipeline.plan.range.location, 0)
            XCTAssertEqual(pipeline.plan.resultingText, expected)
            XCTAssertTrue(pipeline.request.permitsAutomaticContext(.prose, plan: pipeline.plan))
        }
        // После внешней кавычки апостроф остаётся частью полного раскладочного слова.
        let input = "let message = \"'nj\" "
        let pipeline = try pipeline(input)
        XCTAssertEqual(pipeline.candidate.word, "'nj")
        XCTAssertEqual(pipeline.plan.resultingText, "let message = \"это\" ")
        XCTAssertTrue(pipeline.request.permitsAutomaticContext(source(input), plan: pipeline.plan))
    }

    @MainActor
    func testQuotedRussianTypingConvertsToEnglishWithoutChangingTheQuote() throws {
        let input = "let message = \"руддщ "
        let pipeline = try pipeline(input, layout: .russian)
        XCTAssertEqual(pipeline.candidate.word, "руддщ")
        XCTAssertEqual(pipeline.plan.receipt.original, "руддщ")
        XCTAssertEqual(pipeline.plan.receipt.converted, "hello")
        XCTAssertEqual(pipeline.plan.resultingText, "let message = \"hello ")
        XCTAssertTrue(pipeline.request.permitsAutomaticContext(source(input), plan: pipeline.plan))
    }

    func testCommonApostropheWordsAreNeverSplitInternally() throws {
        let (coordinator, _) = try coordinator()
        for word in ["don't", "can't", "it's", "we're", "o'clock", "'tis"] {
            for prefix in ["", "\"", "'"] {
                XCTAssertNil(coordinator.evaluate(context: try context(prefix + word + " ")))
            }
        }
        XCTAssertNil(coordinator.evaluate(context: try context("word'ghbdtn ")))
    }

    func testOtherLeadingLayoutPunctuationIsNotDiscarded() throws {
        let (coordinator, _) = try coordinator()
        for input in [";ghbdtn ", "`ghbdtn ", "]ghbdtn ", "[ghbdtn "] {
            XCTAssertNil(coordinator.evaluate(context: try context(input)))
        }
    }

    @MainActor
    func testCandidateStillRequiresLexicalPermission() throws {
        let code = "let ghbdtn "
        let identifier = try pipeline(code)
        XCTAssertFalse(identifier.request.permitsAutomaticContext(source(code), plan: identifier.plan))
        let character = "int token = 'ghbdtn "
        let literal = try pipeline(character)
        XCTAssertFalse(literal.request.permitsAutomaticContext(source(character, .cLike), plan: literal.plan))
        let interpolated = "let message = \"prefix \\(object) ghbdtn "
        let complex = try pipeline(interpolated)
        XCTAssertFalse(complex.request.permitsAutomaticContext(source(interpolated), plan: complex.plan))
        let comment = "// ghbdtn "
        let allowed = try pipeline(comment)
        XCTAssertTrue(allowed.request.permitsAutomaticContext(source(comment), plan: allowed.plan))
    }

    @MainActor
    func testFullWordPriorityDoesNotConsumeAnAmbiguousStringDelimiter() throws {
        // Полное "nj соответствует «Это», но его диапазон охватывает открывающую кавычку.
        let input = "let message = \"nj "
        let pipeline = try pipeline(input)
        XCTAssertEqual(pipeline.candidate.word, "\"nj")
        XCTAssertFalse(pipeline.request.permitsAutomaticContext(source(input), plan: pipeline.plan))
    }

    func testMixedCaseDigitsShortAndUnknownWordsStayBlocked() throws {
        let (coordinator, _) = try coordinator()
        for word in ["ghBdtn", "ghbdtn1", "ab", "qwertz"] {
            for quote in ["\"", "'", "\"\"\""] {
                XCTAssertNil(coordinator.evaluate(context: try context(quote + word + " ")))
            }
        }
        let upper = try pipeline("let message = \"GHBDTN ")
        XCTAssertEqual(upper.plan.resultingText, "let message = \"ПРИВЕТ ")
    }

    func testFullIntermediateAndBarePersonalExclusionsCannotBeBypassed() throws {
        for excluded in ["\"'ghbdtn", "'ghbdtn", "ghbdtn"] {
            let (coordinator, personal) = try coordinator()
            personal.add(excluded)
            XCTAssertNil(coordinator.evaluate(context: try context("\"'ghbdtn ")))
        }
        let (coordinator, personal) = try coordinator()
        personal.add("'nj")
        XCTAssertNil(coordinator.evaluate(context: try context("'nj ")))
    }

    @MainActor
    func testPrefixTailUTF16CaretAndUndoRemainExact() throws {
        let prefix = "let emoji = \"😀\"; let message = \""
        let tail = "\",  \n"
        let input = prefix + "ghbdtn" + tail
        let pipeline = try pipeline(input)
        XCTAssertEqual(pipeline.candidate.trailingText, tail)
        XCTAssertEqual(pipeline.plan.range.location, prefix.utf16.count)
        XCTAssertEqual(pipeline.plan.receipt.original, "ghbdtn")
        XCTAssertEqual(pipeline.plan.receipt.trailingText, tail)
        XCTAssertEqual(pipeline.plan.resultingText, prefix + "привет" + tail)
        XCTAssertTrue(pipeline.request.permitsAutomaticContext(source(input), plan: pipeline.plan))
        let undo = ConversionRequest(
            expectedWord: pipeline.plan.receipt.converted, trailingText: tail,
            replacement: pipeline.plan.receipt.original, useSelection: false
        )
        let restored = try XCTUnwrap(AXReplacementPlan(
            text: pipeline.plan.resultingText, selection: pipeline.plan.finalSelection,
            request: undo, transform: undo.converted
        ))
        XCTAssertEqual(restored.resultingText, input)
        XCTAssertEqual(restored.finalSelection, NSRange(location: input.utf16.count, length: 0))
    }

    func testUndoLearningStoresOnlyTheChosenWordAndAppliesOutsideQuotes() throws {
        let (coordinator, personal) = try coordinator()
        for _ in 0..<2 {
            let candidate = try XCTUnwrap(coordinator.evaluate(context: try context("\"ghbdtn ")))
            XCTAssertEqual(candidate.word, "ghbdtn")
            XCTAssertEqual(coordinator.lastAutoConvertedWord, "ghbdtn")
            coordinator.registerUndo()
        }
        XCTAssertTrue(personal.contains("ghbdtn"))
        XCTAssertFalse(personal.contains("\"ghbdtn"))
        XCTAssertNil(coordinator.evaluate(context: try context("ghbdtn ")))
        XCTAssertNil(coordinator.evaluate(context: try context("\"ghbdtn ")))
    }

    func testQuoteFallbackIsBounded() throws {
        let (coordinator, _) = try coordinator()
        XCTAssertNil(coordinator.evaluate(context: try context("\"\"\"\"ghbdtn ")))
    }

    private struct Pipeline {
        let candidate: KeystrokeBuffer.WordContext
        let request: ConversionRequest
        let plan: AXReplacementPlan
    }

    private func pipeline(_ text: String, layout: Layout = .english) throws -> Pipeline {
        let (coordinator, _) = try coordinator()
        let candidate = try XCTUnwrap(coordinator.evaluate(context: try context(text)))
        let request = ConversionRequest(
            expectedWord: candidate.word, trailingText: candidate.trailingText, sourceLayout: layout,
            useSelection: false
        )
        let plan = try XCTUnwrap(AXReplacementPlan(
            text: text, selection: NSRange(location: text.utf16.count, length: 0),
            request: request, transform: request.converted
        ))
        return Pipeline(candidate: candidate, request: request, plan: plan)
    }

    private func context(_ text: String) throws -> KeystrokeBuffer.WordContext {
        let buffer = KeystrokeBuffer()
        let classifier = KeystrokeClassifier()
        for character in text { buffer.append(Keystroke(kind: classifier.classify(character: character))) }
        return try XCTUnwrap(buffer.lastWordContextForAutoSwitch())
    }

    private func coordinator() throws -> (AutoSwitchCoordinator, PersonalDictionary) {
        let suite = "lswitch.tests.quoted-candidate.\(UUID().uuidString)"
        suites.append(suite)
        let personal = PersonalDictionary(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let dictionaries = DictionaryStore { language in
            language == .russian ? ["привет", "это", "ёлка", "кажется", "мир"] : ["hello", "world", "tis"]
        }
        _ = dictionaries.prewarm()
        let coordinator = AutoSwitchCoordinator(
            classifier: WordClassifier(dictionaries: dictionaries, personalDictionary: personal),
            personalDictionary: personal
        )
        return (coordinator, personal)
    }

    private func source(_ text: String, _ language: SourceLanguage = .swift) -> AutomaticTextContext {
        .source(language: language, document: "file:///candidate.swift", characterCount: text.utf16.count)
    }
}
