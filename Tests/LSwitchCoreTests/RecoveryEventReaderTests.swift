import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryEventReaderTests: XCTestCase {
    func testOrderKeepsReleasesEditingCommandsAndMouseWithoutReconstructingText() throws {
        let events = try [
            key("a"), key("duplicate", type: .keyUp), key("ignored", code: 51), key("b"),
            mouse(.leftMouseDragged), key("c", flags: .maskCommand)
        ]
        let projection = RecoveryEventReader().project(events: events, recordIdentifier: UUID())
        XCTAssertNil(projection.failure)
        XCTAssertEqual(projection.entries.map(\.ordinal), Array(0..<events.count))
        XCTAssertEqual(projection.entries.map(\.content), [
            .unicodeFragment(RecoveryUnicodeFragment(text: "a")), .nonText(.keyRelease),
            .nonText(.editingKey(.backspace)), .unicodeFragment(RecoveryUnicodeFragment(text: "b")),
            .nonText(.mouse(button: .left, phase: .drag)), .nonText(.modifiedKey)
        ])
    }

    func testReleaseModifiersAndCommandsDoNotReadTheirUnicodePayload() throws {
        let events = try [
            key("payload", type: .keyUp), key("payload", type: .flagsChanged),
            key("payload", flags: .maskCommand), key("payload", flags: .maskControl),
            key("payload", flags: .maskAlternate), key("payload", flags: .maskSecondaryFn),
            key("payload", code: 123), mouse(.rightMouseUp)
        ]
        // Любое чтение ненулевого payload превысило бы этот бюджет и отклонило всю проекцию.
        let reader = RecoveryEventReader(limits: .init(maximumUTF16Units: 0))
        let projection = reader.project(events: events, recordIdentifier: UUID())
        XCTAssertNil(projection.failure)
        XCTAssertEqual(projection.entries.count, events.count)
        XCTAssertEqual(projection.entries[4].content, .unresolved(.modifierDependentInput))
        XCTAssertEqual(projection.entries[5].content, .unresolved(.modifierDependentInput))
    }

    func testShiftCapsAndUnknownLayoutDoNotRemapOrNormalizePayload() throws {
        let supplied = "яe\u{301}😀"
        let event = try key(supplied, flags: [.maskShift, .maskAlphaShift])
        let projection = RecoveryEventReader().project(events: [event], recordIdentifier: UUID())
        guard case .unicodeFragment(let fragment)? = projection.entries.first?.content else {
            XCTFail("Готовый payload не требует определения раскладки")
            return
        }
        XCTAssertEqual(Array(fragment.text.utf16), Array(supplied.utf16))
        XCTAssertEqual(fragment.evidence, .eventPayloadOnly)
    }

    func testNonCoalescedAndDeviceShiftBitsPreserveOnlyExactEventPayload() throws {
        let cases: [UInt64] = [0x100, 0x2, 0x4, 0x6, 0x20002, 0x20004, 0x102, 0x20104]
        let supplied = "яe\u{301}😀"
        for bits in cases {
            let flags = CGEventFlags(rawValue: bits)
            let event = try key(supplied, flags: flags)
            XCTAssertEqual(event.flags.rawValue, bits)
            let projection = RecoveryEventReader().project(events: [event], recordIdentifier: UUID())
            XCTAssertNil(projection.failure)
            guard case .unicodeFragment(let fragment)? = projection.entries.first?.content else {
                XCTFail("Документированные metadata/Shift bits не закрывают payload: \(bits)")
                continue
            }
            XCTAssertEqual(Array(fragment.text.utf16), Array(supplied.utf16))
            XCTAssertEqual(fragment.evidence, .eventPayloadOnly)
        }
    }

    func testDeviceCommandAndControlBitsRefusePayloadWithOrWithoutAggregateFlag() throws {
        let cases: [(UInt64, CGEventFlags)] = [
            (0x1, .maskControl), (0x2000, .maskControl), (0x8, .maskCommand), (0x10, .maskCommand)
        ]
        let reader = RecoveryEventReader(limits: .init(maximumUTF16Units: 0))
        for (bits, aggregate) in cases {
            let device = CGEventFlags(rawValue: bits)
            let variants = [
                device, device.union(aggregate), device.union([.maskNonCoalesced, .maskShift]),
                device.union(CGEventFlags(rawValue: 0x0100_0080))
            ]
            for flags in variants {
                let event = try key("payload", flags: flags)
                XCTAssertEqual(event.flags, flags)
                let projection = reader.project(events: [event], recordIdentifier: UUID())
                XCTAssertNil(projection.failure)
                XCTAssertEqual(projection.entries.first?.content, .nonText(.modifiedKey))
            }
        }
    }

    func testDeviceOptionBitsRemainUnresolvedWithOrWithoutAggregateFlag() throws {
        let reader = RecoveryEventReader(limits: .init(maximumUTF16Units: 0))
        for bits: UInt64 in [0x20, 0x40] {
            let device = CGEventFlags(rawValue: bits)
            let variants = [
                device, device.union(.maskAlternate), device.union(.maskNonCoalesced),
                device.union(CGEventFlags(rawValue: 0x0100_0080))
            ]
            for flags in variants {
                let event = try key("é", flags: flags)
                XCTAssertEqual(event.flags, flags)
                let projection = reader.project(events: [event], recordIdentifier: UUID())
                XCTAssertNil(projection.failure)
                XCTAssertEqual(projection.entries.first?.content, .unresolved(.modifierDependentInput))
            }
        }
    }

    func testDocumentedStatelessCapsBitsDoNotRecalculatePayloadCase() throws {
        let supplied = "яe\u{301}😀"
        let cases: [UInt64] = [0x80, 0x0100_0000, 0x0100_0080, 0x0101_0180]
        for bits in cases {
            let event = try key(supplied, flags: CGEventFlags(rawValue: bits))
            XCTAssertEqual(event.flags.rawValue, bits)
            let projection = RecoveryEventReader().project(events: [event], recordIdentifier: UUID())
            XCTAssertNil(projection.failure)
            guard case .unicodeFragment(let fragment)? = projection.entries.first?.content else {
                XCTFail("Stateless Caps должен сохранить буквальный payload: \(bits)")
                continue
            }
            XCTAssertEqual(Array(fragment.text.utf16), Array(supplied.utf16))
            XCTAssertEqual(fragment.evidence, .eventPayloadOnly)
        }
    }

    func testKnownDeviceBitsDoNotHideUnknownLowOrHighModifierBits() throws {
        // Эти биты сохраняются в созданном CGEvent; значения выше UInt32 здесь не подходят для fixture.
        let cases: [UInt64] = [0x400, 0x0200_0000, 0x506, 0x0202_0104]
        let reader = RecoveryEventReader(limits: .init(maximumUTF16Units: 0))
        for bits in cases {
            let event = try key("payload", flags: CGEventFlags(rawValue: bits))
            XCTAssertEqual(event.flags.rawValue, bits)
            let projection = reader.project(events: [event], recordIdentifier: UUID())
            XCTAssertNil(projection.failure)
            XCTAssertEqual(projection.entries.first?.content, .unresolved(.unsupportedModifiers))
        }
    }

    func testRepeatedDownsStaySeparateAndNoMissingReleaseIsInvented() throws {
        let first = try key("a")
        let repeatEvent = try key("a")
        repeatEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        let projection = RecoveryEventReader().project(events: [first, repeatEvent], recordIdentifier: UUID())
        XCTAssertEqual(projection.entries.map(\.ordinal), [0, 1])
        XCTAssertEqual(projection.entries.map(\.content), [
            .unicodeFragment(RecoveryUnicodeFragment(text: "a")),
            .unicodeFragment(RecoveryUnicodeFragment(text: "a"))
        ])
    }

    func testEditingKeyClassificationTakesPrecedenceOverMisleadingUnicode() throws {
        let cases: [(CGKeyCode, RecoveryEditingKey)] = [
            (51, .backspace), (117, .forwardDelete), (36, .enter), (76, .enter),
            (48, .tab), (53, .escape), (115, .navigation), (124, .navigation), (122, .function)
        ]
        for (code, expected) in cases {
            let event = try key("text", code: code)
            let projection = RecoveryEventReader().project(events: [event], recordIdentifier: UUID())
            XCTAssertEqual(projection.entries.first?.content, .nonText(.editingKey(expected)))
        }
    }

    func testUnsupportedFlagsAndEventRemainOrderedUnresolvedRecords() throws {
        let event = try key("untrusted", flags: .maskHelp)
        let unknown = try key("untrusted")
        unknown.type = .null
        let projection = RecoveryEventReader().project(events: [event, unknown], recordIdentifier: UUID())
        XCTAssertEqual(projection.entries.map(\.ordinal), [0, 1])
        XCTAssertEqual(projection.entries.map(\.content), [
            .unresolved(.unsupportedModifiers), .unresolved(.unsupportedEvent)
        ])
    }

    func testUnicodeBudgetCountsUTF16UnitsAndDoesNotPublishTruncatedPrefix() throws {
        let reader = RecoveryEventReader(limits: .init(maximumUTF16Units: 3))
        let exact = reader.project(events: try [key("😀"), key("a")], recordIdentifier: UUID())
        XCTAssertNil(exact.failure)
        XCTAssertEqual(exact.entries.count, 2)
        let overflow = reader.project(events: try [key("😀"), key("ab")], recordIdentifier: UUID())
        XCTAssertEqual(overflow.failure, .payloadLimitExceeded)
        XCTAssertTrue(overflow.entries.isEmpty)
        let oversized = reader.project(events: try [key("abcd")], recordIdentifier: UUID())
        XCTAssertEqual(oversized.failure, .payloadLimitExceeded)
        XCTAssertTrue(oversized.entries.isEmpty)
    }

    func testEventBudgetRefusesWholeProjectionAndLimitsCannotBeRaised() throws {
        let event = try key("a")
        let reader = RecoveryEventReader(limits: .init(maximumEvents: 1))
        let refused = reader.project(events: [event, event], recordIdentifier: UUID())
        XCTAssertEqual(refused.failure, .eventLimitExceeded)
        XCTAssertTrue(refused.entries.isEmpty)
        let limits = RecoveryProjectionLimits(maximumEvents: .max, maximumUTF16Units: .max)
        XCTAssertEqual(limits.maximumEvents, 256)
        XCTAssertEqual(limits.maximumUTF16Units, 32_768)
        let defaults = RecoveryEventReader().project(
            events: Array(repeating: event, count: 257), recordIdentifier: UUID()
        )
        XCTAssertEqual(defaults.failure, .eventLimitExceeded)
        XCTAssertTrue(defaults.entries.isEmpty)
    }

    func testEmptyRecordAndObserverExposeNoRawEventOrImplicitRead() {
        var calls = 0
        let reader = RecoveryEventReader(onRead: { calls += 1 })
        XCTAssertEqual(calls, 0)
        let identifier = UUID()
        let projection = reader.project(events: [], recordIdentifier: identifier)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(projection.recordIdentifier, identifier)
        XCTAssertTrue(projection.entries.isEmpty)
        XCTAssertNil(projection.failure)
    }

    func testProjectionDoesNotMutateStoredEventPayloadOrMetadata() throws {
        let event = try key("e\u{301}😀", flags: .maskShift)
        event.setIntegerValueField(.eventSourceUserData, value: 712_345)
        let before = unicode(event)
        let first = RecoveryEventReader().project(events: [event], recordIdentifier: UUID())
        let second = RecoveryEventReader().project(events: [event], recordIdentifier: first.recordIdentifier)
        XCTAssertEqual(first, second)
        XCTAssertEqual(unicode(event), before)
        XCTAssertEqual(event.flags, .maskShift)
        XCTAssertEqual(event.type, .keyDown)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), 712_345)
    }

    private func key(
        _ text: String, type: CGEventType = .keyDown, code: CGKeyCode = 0, flags: CGEventFlags = []
    ) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type == .keyDown))
        event.type = type
        event.flags = flags
        let units = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        return event
    }

    private func mouse(_ type: CGEventType) throws -> CGEvent {
        try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .left))
    }

    private func unicode(_ event: CGEvent) -> [UInt16] {
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
        guard count > 0 else { return [] }
        var units = [UniChar](repeating: 0, count: count)
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        return units
    }
}
