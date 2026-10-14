@testable import LSwitchCore
import XCTest

final class LayoutManagerMappingTests: XCTestCase {

    func testRussianLayouts() {
        XCTAssertEqual(LayoutManager.layout(forSourceID: "com.apple.keylayout.Russian"), .russian)
        XCTAssertEqual(LayoutManager.layout(forSourceID: "com.apple.keylayout.RussianWin"), .russian)
    }

    func testEnglishLayouts() {
        XCTAssertEqual(LayoutManager.layout(forSourceID: "com.apple.keylayout.ABC"), .english)
        XCTAssertEqual(LayoutManager.layout(forSourceID: "com.apple.keylayout.US"), .english)
    }

    func testUnsupportedLayout() {
        XCTAssertNil(LayoutManager.layout(forSourceID: "com.apple.keylayout.German"))
        XCTAssertNil(LayoutManager.layout(forSourceID: "com.apple.keylayout.French"))
    }

    /// Проверка против реальной системы: хотя бы одна раскладка ru/en
    /// должна распознаваться (на машине разработчика они есть).
    func testCurrentLayoutIsRecognized() throws {
        let manager = LayoutManager()
        let sourceID = try XCTUnwrap(manager.currentSourceID(), "Нет текущего источника ввода")
        XCTAssertNotNil(
            LayoutManager.layout(forSourceID: sourceID),
            "Текущая раскладка \(sourceID) не распознана — дополни сопоставление"
        )
    }
}

final class DoubleShiftDetectorTests: XCTestCase {

    private var detector = DoubleShiftDetector()

    private func shiftDown(at timestamp: UInt64, keyCode: UInt16 = 56) -> RawKeyEvent {
        RawKeyEvent(
            type: .flagsChanged, keyCode: keyCode, characters: "",
            modifierFlags: CGEventFlags.maskShift.rawValue, isSynthetic: false, timestamp: timestamp
        )
    }

    private func shiftUp(at timestamp: UInt64) -> RawKeyEvent {
        RawKeyEvent(
            type: .flagsChanged, keyCode: 56, characters: "",
            modifierFlags: 0, isSynthetic: false, timestamp: timestamp
        )
    }

    private func letterDown(at timestamp: UInt64) -> RawKeyEvent {
        RawKeyEvent(
            type: .keyDown, keyCode: 0, characters: "a",
            modifierFlags: 0, isSynthetic: false, timestamp: timestamp
        )
    }

    func testDoubleShiftTriggers() {
        XCTAssertFalse(detector.handle(shiftDown(at: 0)))
        XCTAssertFalse(detector.handle(shiftUp(at: 100_000_000)))
        XCTAssertTrue(detector.handle(shiftDown(at: 300_000_000)))
    }

    func testSlowDoubleShiftDoesNotTrigger() {
        XCTAssertFalse(detector.handle(shiftDown(at: 0)))
        XCTAssertFalse(detector.handle(shiftUp(at: 100_000_000)))
        // Интервал 600 мс > 500 мс — вторая становится «первой» новой пары.
        XCTAssertFalse(detector.handle(shiftDown(at: 600_000_000)))
    }

    func testLetterBetweenShiftsResets() {
        XCTAssertFalse(detector.handle(shiftDown(at: 0)))
        XCTAssertFalse(detector.handle(letterDown(at: 100_000_000)))
        XCTAssertFalse(detector.handle(shiftDown(at: 200_000_000)))
    }

    func testShiftLetterCombinationDoesNotTrigger() {
        // Shift+A: флаги с maskShift на keyDown буквы.
        let shiftA = RawKeyEvent(
            type: .keyDown, keyCode: 0, characters: "A",
            modifierFlags: CGEventFlags.maskShift.rawValue, isSynthetic: false, timestamp: 100_000_000
        )
        XCTAssertFalse(detector.handle(shiftDown(at: 0)))
        XCTAssertFalse(detector.handle(shiftA))
        XCTAssertFalse(detector.handle(shiftDown(at: 200_000_000)))
    }

    func testLeftAndRightShiftAreEquivalent() {
        XCTAssertFalse(detector.handle(shiftDown(at: 0, keyCode: 56)))
        XCTAssertTrue(detector.handle(shiftDown(at: 200_000_000, keyCode: 60)))
    }

    func testSyntheticShiftIgnored() {
        let synthetic = RawKeyEvent(
            type: .flagsChanged, keyCode: 56, characters: "",
            modifierFlags: CGEventFlags.maskShift.rawValue, isSynthetic: true, timestamp: 0
        )
        XCTAssertFalse(detector.handle(synthetic))
        // Синтетика не засчиталась как первое нажатие: далее одиночный Shift не триггерит.
        XCTAssertFalse(detector.handle(shiftDown(at: 200_000_000)))
    }

    func testOtherModifierResets() {
        XCTAssertFalse(detector.handle(shiftDown(at: 0)))
        let cmdDown = RawKeyEvent(
            type: .flagsChanged, keyCode: 55, characters: "",
            modifierFlags: CGEventFlags.maskCommand.rawValue, isSynthetic: false, timestamp: 100_000_000
        )
        XCTAssertFalse(detector.handle(cmdDown))
        XCTAssertFalse(detector.handle(shiftDown(at: 200_000_000)))
    }
}
