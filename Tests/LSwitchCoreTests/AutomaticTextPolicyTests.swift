import Foundation
@testable import LSwitchCore
import XCTest

final class AutomaticTextPolicyTests: XCTestCase {
    func testUnseenIdentifiersAreCodeWithoutAWordBlacklist() {
        for language in [SourceLanguage.swift, .javascript, .python, .cLike] {
            for prefix in ["let ", "const ", "var ", "func ", "def ", "return ", "object."] {
                XCTAssertEqual(region(prefix + "ytpfdbcbvsq ", language: language), .code)
            }
        }
    }

    func testLineAndBlockCommentsAcrossLanguages() {
        for language in [SourceLanguage.swift, .javascript, .cLike] {
            XCTAssertEqual(region("let value = 1 // ghbdtn ", language: language), .comment)
            XCTAssertEqual(region("/* first\n ghbdtn ", language: language), .comment)
            XCTAssertEqual(region("// previous\nlet ghbdtn ", language: language), .code)
            XCTAssertEqual(region("/* previous */ let ghbdtn ", language: language), .code)
        }
        XCTAssertEqual(region("value = 1 # ghbdtn ", language: .python), .comment)
        XCTAssertEqual(region("# previous\nghbdtn ", language: .python), .code)
    }

    func testOrdinaryStringsAndEscapedQuotes() {
        for language in [SourceLanguage.swift, .javascript, .python, .cLike] {
            XCTAssertEqual(region("value = \"ghbdtn ", language: language), .string)
            XCTAssertEqual(region("value = \"escaped \\\" ghbdtn ", language: language), .string)
            XCTAssertEqual(region("value = \"done\"; ghbdtn ", language: language), .code)
            XCTAssertEqual(region("//not a comment", word: "comment", language: language),
                           language == .python ? .code : .comment)
        }
        XCTAssertEqual(region("value = 'ghbdtn ", language: .python), .string)
        XCTAssertEqual(region("value = 'ghbdtn ", language: .javascript), .string)
    }

    func testMultilineStringsAndNestedSwiftComments() {
        for language in [SourceLanguage.swift, .python] {
            XCTAssertEqual(region("value = \"\"\"first\n ghbdtn ", language: language), .string)
            XCTAssertEqual(region("value = \"\"\"first\n\"\"\"\nghbdtn ", language: language), .code)
        }
        XCTAssertEqual(region("'''first\n ghbdtn ", language: .python), .string)
        XCTAssertEqual(region("/* outer /* inner */ ghbdtn ", language: .swift), .comment)
        XCTAssertEqual(region("/* outer /* inner */ end */ ghbdtn ", language: .swift), .code)
        XCTAssertEqual(region("/* outer /* inner */ ghbdtn ", language: .cLike), .unknown)
    }

    func testCLikeCharacterConstantsAreCodeRatherThanStrings() {
        XCTAssertEqual(region("int token = 'rfr'; ", word: "rfr", language: .cLike), .code)
        XCTAssertEqual(region("int token = 'ghbdtn ", language: .cLike), .code)
        XCTAssertEqual(region("char *text = \"ghbdtn ", language: .cLike), .string)
    }

    func testComplexLiteralsFailClosed() {
        let fixtures: [(SourceLanguage, String)] = [
            (.swift, "let value = #\"ghbdtn "),
            (.swift, "let value = \"prefix \\(object) ghbdtn "),
            (.javascript, "const value = `prefix ${object} ghbdtn "),
            (.javascript, "const value = /\"/; ghbdtn "),
            (.python, "value = f\"prefix {object} ghbdtn "),
            (.python, "value = r\"prefix ghbdtn "),
            (.cLike, "var value = $\"prefix {object} ghbdtn "),
            (.cLike, "auto value = R\"(prefix ghbdtn "),
            (.cLike, "val value = \"prefix ${object} ghbdtn ")
        ]
        for (language, text) in fixtures { XCTAssertEqual(region(text, language: language), .unknown) }
    }

    func testUTF16CoordinatesAndInvalidScalarBoundary() {
        let text = "let emoji = \"😀\" // ghbdtn "
        XCTAssertEqual(region(text), .comment)
        let emoji = (text as NSString).range(of: "😀")
        XCTAssertEqual(AutomaticTextPolicy.region(
            text: text, wordRange: NSRange(location: emoji.location + 1, length: 1), context: source(text)
        ), .unknown)
    }

    func testUnicodePreprocessingAndLineSplicingCannotHideCodeInComments() {
        let fixtures = [
            "// \\u000a int ghbdtn ", "/* \\u002a/ int ghbdtn ",
            "/* text *\\\n/ int ghbdtn ", "/* text *??/\n/ int ghbdtn ",
            "/* text *\\  \n/ int ghbdtn ", "/* text *\\\t\n/ int ghbdtn ",
            "String text = \"\\u0022; int ghbdtn "
        ]
        for text in fixtures { XCTAssertEqual(region(text, language: .cLike), .unknown) }
    }

    func testJavaScriptUnicodeLineSeparatorsEndComments() {
        for separator in ["\u{2028}", "\u{2029}"] {
            XCTAssertEqual(region("// previous" + separator + "let ghbdtn ", language: .javascript), .code)
        }
    }

    func testUnverifiedVirtualizedFragmentNeverLooksLikeAString() {
        let fragment = "done\"; int ghbdtn "
        XCTAssertEqual(AutomaticTextPolicy.region(
            text: fragment, wordRange: (fragment as NSString).range(of: "ghbdtn"),
            context: .unverifiedSource(document: "file:///test.js")
        ), .unknown)
    }

    func testMissingTruncatedAndOverBudgetSnapshotAreUnknown() {
        let text = "// ghbdtn "
        for count in [nil, text.utf16.count - 1, text.utf16.count + 1] {
            XCTAssertEqual(AutomaticTextPolicy.region(
                text: text, wordRange: (text as NSString).range(of: "ghbdtn"),
                context: .source(language: .swift, document: "file:///test.swift", characterCount: count)
            ), .unknown)
        }
        let large = "//" + String(repeating: " ", count: AutomaticTextPolicy.maximumUTF16Count) + "ghbdtn "
        XCTAssertEqual(region(large), .unknown)
    }

    func testWordCrossingLexicalBoundaryIsUnknown() {
        XCTAssertEqual(region("let value = \"abc\"code ", word: "abc\"code"), .unknown)
        XCTAssertEqual(region("let value = \"bad\n ghbdtn "), .unknown)
    }

    func testProseDoesNotBecomeCodeFromItsText() {
        let text = "let ghbdtn "
        XCTAssertEqual(AutomaticTextPolicy.region(
            text: text, wordRange: (text as NSString).range(of: "ghbdtn"), context: .prose
        ), .prose)
        XCTAssertEqual(AutomaticTextPolicy.region(
            text: text, wordRange: (text as NSString).range(of: "ghbdtn"), context: .unknown
        ), .unknown)
    }

    private func region(
        _ text: String, word: String? = nil, language: SourceLanguage = .swift
    ) -> AutomaticTextPolicy.Region {
        let target = word ?? (text.contains("ytpfdbcbvsq") ? "ytpfdbcbvsq" : "ghbdtn")
        return AutomaticTextPolicy.region(
            text: text, wordRange: (text as NSString).range(of: target), context: source(text, language: language)
        )
    }

    private func source(_ text: String, language: SourceLanguage = .swift) -> AutomaticTextContext {
        .source(language: language, document: "file:///test.swift", characterCount: text.utf16.count)
    }
}
