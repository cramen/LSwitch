import CoreGraphics
import Dispatch
import Foundation
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
    @MainActor
    func testMarkedKeyDownImageIsExcludedFromDownstreamProcessing() async throws {
        // Только объекты в памяти: ни один keyDown этого теста не отправляется в систему.
        let own = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 5, keyDown: true))
        let foreign = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 5, keyDown: true))
        for event in [own, foreign] {
            // Fixture символа не наследует реально удерживаемые пользователем Cmd/Ctrl/Option.
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: [0x67])
        }
        XCTAssertTrue(SyntheticEventMarker.tag(own))
        let core = EventTapCore { _ in }
        let ownRaw = try XCTUnwrap(core.correctedRawEvent(type: .keyDown, event: own))
        let foreignRaw = try XCTUnwrap(core.correctedRawEvent(type: .keyDown, event: foreign))
        let classifier = KeystrokeClassifier()
        XCTAssertTrue(ownRaw.isSynthetic)
        XCTAssertFalse(foreignRaw.isSynthetic)
        XCTAssertNil(classifier.classify(ownRaw))
        XCTAssertEqual(classifier.classify(foreignRaw), .character("g"))
        let buffer = KeystrokeBuffer()
        buffer.append(Keystroke(kind: .character("g"), isSynthetic: ownRaw.isSynthetic))
        XCTAssertEqual(buffer.count, 0)
        buffer.append(Keystroke(kind: .character("g"), isSynthetic: foreignRaw.isSynthetic))
        XCTAssertEqual(buffer.lastWord(), "g")
        var detector = DoubleShiftDetector()
        for timestamp: UInt64 in [10, 100] {
            XCTAssertFalse(detector.handle(RawKeyEvent(
                type: .flagsChanged, keyCode: 56, characters: "", modifierFlags: CGEventFlags.maskShift.rawValue,
                isSynthetic: ownRaw.isSynthetic, timestamp: timestamp
            )))
        }
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
/// Skip не является доказательством приёмки. После успешной доставки внешнего
/// keyUp отсутствие собственного события или потеря его метки — failure, не skip.
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

    @MainActor
    func testSyntheticMarkerSurvivesRealTapDeliveryWithoutRecursion() async throws {
        guard CGPreflightListenEventAccess(), CGPreflightPostEventAccess() else {
            throw XCTSkip("Нет разрешений на чтение/отправку событий; реальная доставка метки не проверена")
        }
        let receivedOrdinary = XCTestExpectation(description: "Доставлен внешний keyUp")
        let receivedMarked = XCTestExpectation(description: "Доставлен маркированный keyUp")
        let collector = DeliveredKeyUps()
        let tap = EventTapCore { raw in
            switch collector.record(raw) {
            case .ordinary: receivedOrdinary.fulfill()
            case .marked: receivedMarked.fulfill()
            case nil: break
            }
        }
        guard tap.start() else { throw XCTSkip("Tap не создан; реальная доставка метки не проверена") }
        defer { tap.stop() }
        // Глобально посылается только отпускание клавиши: символы и команды не вводятся.
        try postKeyUp(.ordinary, collector: collector)
        let ordinaryResult = await XCTWaiter().fulfillment(of: [receivedOrdinary], timeout: 5)
        guard ordinaryResult == .completed else {
            throw XCTSkip("Внешний keyUp не доставлен; окружение не подтвердило работу event tap")
        }
        try postKeyUp(.marked, collector: collector)
        let markedResult = await XCTWaiter().fulfillment(of: [receivedMarked], timeout: 5)
        XCTAssertEqual(markedResult, .completed, "Внешняя доставка работает: отсутствие своего события — ошибка")
        try await Task.sleep(nanoseconds: 100_000_000)
        let ordinaryEvents = collector.events(for: .ordinary)
        let markedEvents = collector.events(for: .marked)
        XCTAssertEqual(ordinaryEvents.count, 1)
        XCTAssertEqual(markedEvents.count, 1, "Событие не должно повторно публиковаться")
        XCTAssertFalse(try XCTUnwrap(ordinaryEvents.first).isSynthetic)
        XCTAssertTrue(try XCTUnwrap(markedEvents.first).isSynthetic)
        XCTAssertTrue(collector.allEventsAreKeyUp)
    }

    private func postKeyUp(_ kind: DeliveredKeyUps.Kind, collector: DeliveredKeyUps) throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x21, keyDown: false))
        event.flags = []
        if kind == .marked {
            XCTAssertTrue(SyntheticEventMarker.tag(event))
            guard SyntheticEventMarker.isSynthetic(event) else { return }
        } else {
            XCTAssertFalse(SyntheticEventMarker.isSynthetic(event))
        }
        // CGEvent нельзя готовить до await: при позднем post timestamp может измениться.
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        collector.expect(kind, timestamp: event.timestamp)
        XCTAssertEqual(event.type, .keyUp)
        event.post(tap: .cghidEventTap)
    }
}

/// Callback пишет с processingQueue; XCTest читает только под тем же замком.
private final class DeliveredKeyUps: @unchecked Sendable {
    enum Kind { case ordinary, marked }
    private let lock = NSLock()
    private var expected: [UInt64: Kind] = [:]
    private var received: [Kind: [RawKeyEvent]] = [:]

    func expect(_ kind: Kind, timestamp: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        expected[timestamp] = kind
    }

    func record(_ raw: RawKeyEvent) -> Kind? {
        guard raw.type == .keyUp, raw.keyCode == 0x21 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let kind = expected[raw.timestamp] else { return nil }
        let first = received[kind, default: []].isEmpty
        received[kind, default: []].append(raw)
        return first ? kind : nil
    }

    func events(for kind: Kind) -> [RawKeyEvent] {
        lock.lock()
        defer { lock.unlock() }
        return received[kind, default: []]
    }

    var allEventsAreKeyUp: Bool {
        lock.lock()
        defer { lock.unlock() }
        return received.values.flatMap { $0 }.allSatisfy { $0.type == .keyUp }
    }
}
