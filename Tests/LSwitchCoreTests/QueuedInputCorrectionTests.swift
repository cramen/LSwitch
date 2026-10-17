import CoreGraphics
import Dispatch
@testable import LSwitchCore
import XCTest

final class QueuedInputCorrectionTests: XCTestCase {
    private let russianToEnglish = QueuedInputCorrection(
        from: .russian, to: .english, startedAt: 100, completedAt: 200
    )

    private func event(
        _ text: String = "ц",
        timestamp: UInt64 = 150,
        type: RawKeyEventType = .keyDown,
        modifiers: CGEventFlags = [],
        synthetic: Bool = false
    ) -> RawKeyEvent {
        RawKeyEvent(
            type: type, keyCode: 13, characters: text, modifierFlags: modifiers.rawValue,
            isSynthetic: synthetic, timestamp: timestamp
        )
    }

    func testBothClosedTimeBoundariesAreCorrected() {
        for timestamp: UInt64 in [100, 150, 200] {
            let original = event(timestamp: timestamp)
            let corrected = russianToEnglish.corrected(original)
            XCTAssertEqual(corrected.characters, "w")
            XCTAssertEqual(corrected.timestamp, timestamp)
            XCTAssertEqual(corrected.keyCode, original.keyCode)
            XCTAssertEqual(corrected.modifierFlags, original.modifierFlags)
            XCTAssertFalse(corrected.isSynthetic)
        }
    }

    func testEventsBeforeAndAfterWindowStayUnchanged() {
        for timestamp: UInt64 in [0, 99, 201, UInt64.max] {
            let original = event(timestamp: timestamp)
            XCTAssertEqual(russianToEnglish.corrected(original), original)
        }
    }

    func testOnlyKeyDownIsCorrected() {
        for type: RawKeyEventType in [.keyUp, .flagsChanged, .other] {
            let original = event(type: type)
            XCTAssertEqual(russianToEnglish.corrected(original), original)
        }
    }

    func testOwnSyntheticAndCommandModifiedKeysStayUnchanged() {
        let synthetic = event(synthetic: true)
        XCTAssertEqual(russianToEnglish.corrected(synthetic), synthetic)
        for modifier: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate, [.maskCommand, .maskShift]] {
            let original = event(modifiers: modifier)
            XCTAssertEqual(russianToEnglish.corrected(original), original)
        }
    }

    func testShiftPreservesUppercaseAndFlags() {
        let original = event("Ц", modifiers: .maskShift)
        let corrected = russianToEnglish.corrected(original)
        XCTAssertEqual(corrected.characters, "W")
        XCTAssertEqual(corrected.modifierFlags, CGEventFlags.maskShift.rawValue)
    }

    func testTrackedDeviceOnlyShortcutAndUnknownBitsArePreserved() {
        let bits: [UInt64] = [0x01, 0x08, 0x10, 0x20, 0x40, 0x2000, 0x8000, 0x2000_0000, 1 << 60]
        for bit in bits {
            let original = event("Ц", modifiers: CGEventFlags(rawValue: bit))
            XCTAssertEqual(russianToEnglish.correctedTracked(original), original)
        }
        for bit: UInt64 in [0x02, 0x04, 0x0100_0080] {
            let original = event("Ц", modifiers: CGEventFlags(rawValue: bit))
            XCTAssertEqual(russianToEnglish.correctedTracked(original).characters, "W")
        }
    }

    func testLegacyUnknownFlagsKeepPreviousGenericModifierBehavior() {
        let original = event("ц", modifiers: CGEventFlags(rawValue: 0x2000_0000))
        let corrected = russianToEnglish.corrected(original)
        XCTAssertEqual(corrected.characters, "w")
        XCTAssertEqual(corrected.modifierFlags, original.modifierFlags)
        XCTAssertEqual(corrected.timestamp, original.timestamp)
        XCTAssertEqual(russianToEnglish.correctedTracked(original), original)
    }

    func testBothDirectionsUseExplicitPunctuationMapping() {
        let englishToRussian = QueuedInputCorrection(
            from: .english, to: .russian, startedAt: 100, completedAt: 200
        )
        XCTAssertEqual(englishToRussian.corrected(event("vbh/;")).characters, "мир.ж")
        XCTAssertEqual(russianToEnglish.corrected(event("цщкдв.,")).characters, "world/?")
    }

    func testEmptyAndUnmappedTextStayUnchanged() {
        for text in ["", "🙂123 ", "\n"] {
            let original = event(text)
            XCTAssertEqual(russianToEnglish.corrected(original), original)
        }
    }

    func testInvalidWindowAndUnchangedLayoutDoNothing() {
        let invalid = QueuedInputCorrection(from: .russian, to: .english, startedAt: 200, completedAt: 100)
        let unchanged = QueuedInputCorrection(from: .russian, to: .russian, startedAt: 100, completedAt: 200)
        let original = event()
        XCTAssertEqual(invalid.corrected(original), original)
        XCTAssertEqual(unchanged.corrected(original), original)
    }

    @MainActor
    func testCallbackSnapshotAndOriginalCGEventReceiveSameUnicodeWithoutPosting() async throws {
        let tap = EventTapCore { _ in XCTFail("Проверка не должна доставлять события в обработчик") }
        let source = CGEventSource(stateID: .hidSystemState)
        let keyboard = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 13, keyDown: true))
        // Исследуется unmodified input, а не неявное текущее состояние физической клавиатуры машины.
        keyboard.flags = []
        let startedAt = DispatchTime.now().uptimeNanoseconds
        keyboard.timestamp = startedAt
        let original = Array("ц".utf16)
        keyboard.keyboardSetUnicodeString(stringLength: original.count, unicodeString: original)
        tap.recordLayoutChange(from: .russian, to: .english, since: startedAt)
        let snapshot = try XCTUnwrap(tap.correctedRawEvent(type: .keyDown, event: keyboard))
        XCTAssertEqual(snapshot.characters, "w")
        XCTAssertEqual(snapshot.timestamp, startedAt)
        XCTAssertEqual(snapshot.keyCode, 13)
        var units = [UniChar](repeating: 0, count: 8)
        var length = 0
        keyboard.keyboardGetUnicodeString(
            maxStringLength: units.count, actualStringLength: &length, unicodeString: &units
        )
        XCTAssertEqual(String(decoding: units.prefix(length), as: UTF16.self), "w")
        XCTAssertFalse(SyntheticEventMarker.isSynthetic(keyboard))
    }
}
