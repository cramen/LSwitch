import XCTest
@testable import LSwitchCore

final class WordBoundaryTests: XCTestCase {

    private func word(in text: String, cursorOffset: Int? = nil) -> String? {
        let cursor = cursorOffset.map { text.index(text.startIndex, offsetBy: $0) } ?? text.endIndex
        guard let range = WordBoundary.lastWord(in: text, beforeCursor: cursor) else { return nil }
        return String(text[range])
    }

    func testWordAtEnd() {
        XCTAssertEqual(word(in: "ghbdtn"), "ghbdtn")
    }

    func testWordBeforeTrailingDelimiter() {
        XCTAssertEqual(word(in: "ghbdtn "), "ghbdtn")
        XCTAssertEqual(word(in: "ghbdtn, "), "ghbdtn")
    }

    func testLastOfTwoWords() {
        XCTAssertEqual(word(in: "привет мир"), "мир")
    }

    func testCursorInMiddle() {
        XCTAssertEqual(word(in: "hello world", cursorOffset: 5), "hello")
    }

    func testNoWordBeforeCursor() {
        XCTAssertNil(word(in: "   "))
        XCTAssertNil(word(in: ""))
    }

    func testCursorAtStart() {
        XCTAssertNil(word(in: "hello", cursorOffset: 0))
    }

    func testDigitsAreNotWordCharacters() {
        XCTAssertEqual(word(in: "abc123"), "abc")
        XCTAssertNil(word(in: "123"))
    }

    func testMixedCyrillicLatin() {
        XCTAssertEqual(word(in: "слово word"), "word")
    }

    func testUnicodeLetters() {
        XCTAssertEqual(word(in: "café"), "café")
    }
}
