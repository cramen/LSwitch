import XCTest
@testable import LSwitchCore

final class LayoutMapTests: XCTestCase {

    let map = LayoutMap.shared

    func testEnglishToRussian() {
        XCTAssertEqual(map.convert("ghbdtn", from: .english, to: .russian), "привет")
        XCTAssertEqual(map.convert("vbh", from: .english, to: .russian), "мир")
    }

    func testRussianToEnglish() {
        XCTAssertEqual(map.convert("руддщ", from: .russian, to: .english), "hello")
        XCTAssertEqual(map.convert("Цщкдв", from: .russian, to: .english), "World")
    }

    func testCasePreserved() {
        XCTAssertEqual(map.convert("Ghbdtn", from: .english, to: .russian), "Привет")
        XCTAssertEqual(map.convert("GHBDTN", from: .english, to: .russian), "ПРИВЕТ")
    }

    func testYoAndHardSign() {
        XCTAssertEqual(map.convert("ёжъ", from: .russian, to: .english), "`;]")
        XCTAssertEqual(map.convert("`", from: .english, to: .russian), "ё")
    }

    func testRussianPunctuation() {
        XCTAssertEqual(map.convert("/", from: .english, to: .russian), ".")
        XCTAssertEqual(map.convert("?", from: .english, to: .russian), ",")
        XCTAssertEqual(map.convert("#", from: .english, to: .russian), "№")
    }

    func testUnmappedCharactersPassThrough() {
        XCTAssertEqual(map.convert("hello world 123!", from: .english, to: .russian), "руддщ цщкдв 123!")
        XCTAssertEqual(map.convert("—", from: .russian, to: .english), "—")
    }

    func testInvert() {
        XCTAssertEqual(map.invert("ghbdtn"), "привет")
        XCTAssertEqual(map.invert("привет"), "ghbdtn")
        XCTAssertEqual(map.invert(map.invert("съешь ещё")), "съешь ещё")
    }

    func testLayoutDetection() {
        XCTAssertEqual(map.layout(of: "а"), .russian)
        XCTAssertEqual(map.layout(of: "A"), .english)
        XCTAssertNil(map.layout(of: "5"))
        XCTAssertNil(map.layout(of: " "))
    }

    func testEveryLetterRoundTrips() {
        let russianAlphabet = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
        for ch in russianAlphabet {
            let en = map.convert(String(ch), from: .russian, to: .english)
            XCTAssertEqual(map.convert(en, from: .english, to: .russian), String(ch),
                           "Буква \(ch) не выдерживает round-trip")
        }
    }
}
