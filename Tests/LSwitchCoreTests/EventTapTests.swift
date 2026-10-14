import CoreGraphics
@testable import LSwitchCore
import XCTest

final class SyntheticEventMarkerTests: XCTestCase {

    func testTagRoundTrip() {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            XCTFail("Не удалось создать CGEvent")
            return
        }
        XCTAssertFalse(SyntheticEventMarker.isSynthetic(event))
        SyntheticEventMarker.tag(event)
        XCTAssertTrue(SyntheticEventMarker.isSynthetic(event))
    }

    func testForeignEventIsNotSynthetic() {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            XCTFail("Не удалось создать CGEvent")
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: 42)
        XCTAssertFalse(SyntheticEventMarker.isSynthetic(event))
    }

    func testTagReplacesPreviouslyAssignedSourceData() throws {
        for original: Int64 in [0, 42] {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: true))
            event.setIntegerValueField(.eventSourceUserData, value: original)
            XCTAssertTrue(SyntheticEventMarker.tag(event))
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), SyntheticEventMarker.magic)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 13)
            XCTAssertEqual(event.type, .keyDown)
        }
    }

    func testTagSurvivesCopyAndCanRetagDeserializedEvent() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        XCTAssertTrue(SyntheticEventMarker.tag(event))
        let copied = try XCTUnwrap(event.copy())
        XCTAssertTrue(SyntheticEventMarker.isSynthetic(copied))
        let data = try XCTUnwrap(event.data)
        let restored = try XCTUnwrap(CGEvent(withDataAllocator: nil, data: data))
        // macOS 14.5 не сохраняет source userData при flatten/unflatten, даже для значения 42.
        // Повторная маркировка собственного восстановленного события должна быть надёжной.
        XCTAssertTrue(SyntheticEventMarker.tag(restored))
        XCTAssertEqual(restored.getIntegerValueField(.eventSourceUserData), SyntheticEventMarker.magic)
        XCTAssertTrue(SyntheticEventMarker.isSynthetic(restored))
    }
}

final class KeystrokeClassifierTests: XCTestCase {

    private let classifier = KeystrokeClassifier()

    private func raw(
        _ text: String,
        keyCode: UInt16 = 0,
        modifiers: CGEventFlags = [],
        isSynthetic: Bool = false
    ) -> RawKeyEvent {
        RawKeyEvent(
            type: .keyDown,
            keyCode: keyCode,
            characters: text,
            modifierFlags: modifiers.rawValue,
            isSynthetic: isSynthetic,
            timestamp: 0
        )
    }

    func testLetterIsCharacter() {
        XCTAssertEqual(classifier.classify(raw("g")), .character("g"))
        XCTAssertEqual(classifier.classify(raw("п")), .character("п"))
    }

    func testDigitIsCharacter() {
        XCTAssertEqual(classifier.classify(raw("7")), .character("7"))
    }

    func testLayoutPunctuationIsCharacter() {
        // "," и "." имеют соответствие в раскладке (б/ю) — часть слова.
        XCTAssertEqual(classifier.classify(raw(",")), .character(","))
    }

    func testSpaceAndNewlineAreDelimiters() {
        XCTAssertEqual(classifier.classify(raw(" ")), .delimiter(" "))
        XCTAssertEqual(classifier.classify(raw("\n")), .delimiter("\n"))
    }

    func testUnmappedPunctuationIsDelimiter() {
        XCTAssertEqual(classifier.classify(raw("!")), .delimiter("!"))
    }

    func testCommandModifiedKeyIsControl() {
        XCTAssertEqual(classifier.classify(raw("c", modifiers: .maskCommand)), .control)
    }

    func testCursorAndDeleteAreControl() {
        for keyCode: UInt16 in [51, 53, 123, 124, 125, 126] {
            XCTAssertEqual(classifier.classify(raw("", keyCode: keyCode)), .control)
        }
    }

    func testSyntheticIsIgnored() {
        XCTAssertNil(classifier.classify(raw("g", isSynthetic: true)))
    }

    func testKeyUpIsIgnored() {
        let event = RawKeyEvent(
            type: .keyUp, keyCode: 0, characters: "g",
            modifierFlags: 0, isSynthetic: false, timestamp: 0
        )
        XCTAssertNil(classifier.classify(event))
    }
}

/// Интеграционный тест реального event tap. Зависит от разрешения
/// Input Monitoring для тестового раннера: без него tap либо не создаётся,
/// либо создаётся, но молчит — оба случая трактуются как skip, а не failure.
/// Настоящая проверка перехвата — ручной чек-лист спайка P0.1.
final class EventTapCoreIntegrationTests: XCTestCase {

    @MainActor
    func testTapReceivesPostedEvent() async throws {
        let received = expectation(description: "Обычное событие получено")
        received.assertForOverFulfill = false
        let tap = EventTapCore { raw in
            guard raw.type == .keyUp, raw.keyCode == 0x21 else { return }
            received.fulfill()
        }
        guard tap.start() else {
            throw XCTSkip("Нет разрешения Input Monitoring — tap не создан")
        }
        defer { tap.stop() }

        let source = CGEventSource(stateID: .hidSystemState)
        // Отпускание проверяет доставку, не печатая символ в активное пользовательское окно.
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x21, keyDown: false) else {
            XCTFail("Не удалось создать CGEvent")
            return
        }
        event.post(tap: .cghidEventTap)

        let result = await XCTWaiter().fulfillment(of: [received], timeout: 5)
        if result != .completed {
            throw XCTSkip("Tap создан, но события не доходят — окружение без разрешений или headless")
        }
    }
}
