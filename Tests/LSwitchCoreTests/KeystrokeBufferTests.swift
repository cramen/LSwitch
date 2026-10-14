@testable import LSwitchCore
import XCTest

final class KeystrokeBufferTests: XCTestCase {

    var buffer: KeystrokeBuffer!

    override func setUp() {
        buffer = KeystrokeBuffer(capacity: 10)
    }

    private func type(_ text: String) {
        for letter in text {
            if letter == " " || letter == "," || letter == "." || letter == "\n" {
                buffer.append(Keystroke(kind: .delimiter(letter)))
            } else {
                buffer.append(Keystroke(kind: .character(letter)))
            }
        }
    }

    func testLastWord() {
        type("ghbdtn")
        XCTAssertEqual(buffer.lastWord(), "ghbdtn")
    }

    func testLastWordStopsAtDelimiter() {
        type("привет мир")
        XCTAssertEqual(buffer.lastWord(), "мир")
    }

    func testLastWordEmptyAfterDelimiter() {
        type("слово ")
        XCTAssertEqual(buffer.lastWord(), "")
    }

    func testControlClearsBuffer() {
        type("текст")
        buffer.append(Keystroke(kind: .control))
        XCTAssertEqual(buffer.lastWord(), "")
        XCTAssertEqual(buffer.count, 0)
    }

    func testSyntheticEventsIgnored() {
        type("abc")
        buffer.append(Keystroke(kind: .character("x"), isSynthetic: true))
        XCTAssertEqual(buffer.lastWord(), "abc")
    }

    func testCapacityOverflow() {
        type("0123456789ABCDEF") // 16 символов при capacity 10
        XCTAssertEqual(buffer.count, 10)
        XCTAssertEqual(buffer.lastWord(), "6789ABCDEF")
    }

    func testRemoveLastWord() {
        type("один два")
        buffer.removeLastWord()
        XCTAssertEqual(buffer.lastWord(), "")
        buffer.removeLastDelimiter()
        XCTAssertEqual(buffer.lastWord(), "один")
    }

    func testThreadSafety() {
        let iterations = 1000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            self.buffer.append(Keystroke(kind: .character("x")))
            _ = self.buffer.lastWord()
        }
        XCTAssertEqual(buffer.count, 10)
    }
}
