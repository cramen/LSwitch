import CoreGraphics
@testable import LSwitchCore
import XCTest

@MainActor
final class UnicodeEmitterTests: XCTestCase {
    func testPacketHasExactUnicodeAndOwnMarkersOnBothEvents() throws {
        for text in ["привет", "ghbdtn ", String(repeating: "я", count: 32)] {
            let events = try XCTUnwrap(UnicodeEventEmitter.events(for: text))
            XCTAssertTrue(UnicodeEventEmitter.validates(events.down, units: Array(text.utf16), keyDown: true))
            XCTAssertTrue(UnicodeEventEmitter.validates(events.release, units: Array(text.utf16), keyDown: false))
            XCTAssertTrue(SyntheticEventMarker.isSynthetic(events.down))
            XCTAssertTrue(SyntheticEventMarker.isSynthetic(events.release))
        }
    }

    func testModifiedPayloadOrFlagsCannotPassReadback() throws {
        let events = try XCTUnwrap(UnicodeEventEmitter.events(for: "привет"))
        XCTAssertFalse(UnicodeEventEmitter.validates(events.down, units: Array("пока".utf16), keyDown: true))
        events.down.flags = .maskCommand
        XCTAssertFalse(UnicodeEventEmitter.validates(events.down, units: Array("привет".utf16), keyDown: true))
        XCTAssertNil(UnicodeEventEmitter.events(for: "test\n"))
        let unmarked = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        unmarked.keyboardSetUnicodeString(stringLength: 6, unicodeString: Array("привет".utf16))
        XCTAssertFalse(UnicodeEventEmitter.validates(unmarked, units: Array("привет".utf16), keyDown: true))
    }

    func testContextChangeAfterDownStillBalancesSamePIDAndCannotReusePacket() throws {
        var valid = true
        var delivered: [(CGEventType, pid_t)] = []
        let packet = try XCTUnwrap(UnicodeEventEmitter.prepare("привет", targetPID: 123) { event, processID in
            delivered.append((event.type, processID))
            if event.type == .keyDown { valid = false }
        })
        XCTAssertTrue(packet.post { valid })
        XCTAssertEqual(delivered.map(\.0), [.keyDown, .keyUp])
        XCTAssertEqual(delivered.map(\.1), [123, 123])
        valid = true
        XCTAssertFalse(packet.post { valid })
        XCTAssertEqual(delivered.count, 2)
    }

    func testInvalidPreflightDoesNotDeliverEitherEvent() throws {
        var count = 0
        let packet = try XCTUnwrap(UnicodeEventEmitter.prepare("привет", targetPID: 123) { _, _ in count += 1 })
        XCTAssertFalse(packet.post { false })
        XCTAssertEqual(count, 0)
    }

    func testAnotherPhysicalKeyCannotPassPreparedPacketValidation() throws {
        let events = try XCTUnwrap(UnicodeEventEmitter.events(for: "привет"))
        events.down.setIntegerValueField(.keyboardEventKeycode, value: 12)
        XCTAssertFalse(UnicodeEventEmitter.validates(events.down, units: Array("привет".utf16), keyDown: true))
    }
}
