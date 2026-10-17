#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class RecipientEventMatrixTests: XCTestCase {
    func testSubscribedTypesCoverAllDeclaredFamiliesWithoutMouseMovement() {
        XCTAssertEqual(RecipientEventKind.eventTypes.count, RecipientEventKind.allCases.count)
        XCTAssertEqual(Set(RecipientEventKind.eventTypes.map(\.rawValue)).count, 13)
        XCTAssertFalse(RecipientEventKind.eventTypes.contains(.mouseMoved))
        XCTAssertTrue(RecipientEventKind.eventTypes.contains(.scrollWheel))
    }

    func testEveryMouseButtonNumberUsedByPrearmCanBeRepresented() {
        for number in 0..<32 { XCTAssertNotNil(CGMouseButton(rawValue: UInt32(number))) }
    }

    @MainActor
    func testPhysicalMouseStateAfterActivationDoesNotRevokeCaptureLease() throws {
        let fixture = try RecipientTapDriverFixture()
        fixture.state.recordPhysicalButtons(released: false)
        XCTAssertTrue(fixture.state.permitsMutation)
        XCTAssertTrue(fixture.state.snapshot.permitsMutation)
        XCTAssertFalse(fixture.state.snapshot.mouseButtonsReleased)
        fixture.state.markLost(.tapDisabled)
        XCTAssertFalse(fixture.state.permitsMutation)
    }

    @MainActor
    func testProtectedClosedAndLostRejectEveryModifyingFamilyWithoutSubmission() throws {
        for terminal in ["protected", "closed", "lost"] {
            for type in RecipientEventKind.eventTypes where type != .keyUp {
                let fixture = try RecipientTapDriverFixture()
                if terminal == "closed" { fixture.bridge.closeGeneration() }
                if terminal == "lost" { fixture.state.markLost(.peerEOF) }
                let event = try event(type: type, keyCode: 56, flags: .maskShift)
                XCTAssertFalse(fixture.state.observe(type: type, event: event, isHead: true))
                let index = try XCTUnwrap(RecipientEventKind.allCases.firstIndex(of: XCTUnwrap(
                    RecipientEventKind(eventType: type)
                )))
                XCTAssertEqual(fixture.state.snapshot.eventCounters.blocked[index], 1)
                XCTAssertEqual(fixture.bridge.snapshot.ledgerSubmissionCount, 0)
                XCTAssertTrue(fixture.bridge.snapshot.handoverRequested)
            }
        }
    }

    @MainActor
    func testUnprotectedControlForwardsAllFamiliesAndTailKeepsTheirKinds() throws {
        let fixture = try RecipientTapDriverFixture(activate: false)
        for type in RecipientEventKind.eventTypes {
            let event = try event(type: type, keyCode: 56, flags: .maskShift)
            XCTAssertTrue(fixture.state.observe(type: type, event: event, isHead: true))
            XCTAssertTrue(fixture.state.observe(type: type, event: event, isHead: false))
        }
        XCTAssertEqual(fixture.state.snapshot.eventCounters.allowed, Array(repeating: 1, count: 13))
        XCTAssertEqual(fixture.state.snapshot.eventCounters.tail, Array(repeating: 1, count: 13))
        XCTAssertEqual(fixture.bridge.snapshot.ledgerSubmissionCount, 0)
    }

    @MainActor
    func testBlockedModifiersCannotBeIntroducedByAnotherKeysRelease() throws {
        let fixture = try RecipientTapDriverFixture()
        XCTAssertFalse(try sendModifier(56, flags: .maskShift, to: fixture.state))
        XCTAssertFalse(try sendModifier(58, flags: [.maskShift, .maskAlternate], to: fixture.state))
        XCTAssertFalse(try sendModifier(56, flags: .maskAlternate, to: fixture.state))
        XCTAssertTrue(try sendModifier(58, flags: [], to: fixture.state))
        XCTAssertEqual(fixture.state.snapshot.headBlocked, 3)
        XCTAssertEqual(fixture.state.snapshot.headAllowed, 1)
        XCTAssertEqual(fixture.bridge.snapshot.ledgerSubmissionCount, 0)
    }

    @MainActor
    func testPreviouslyForwardedMultipleModifiersCanClearWithoutAddingBits() throws {
        let fixture = try RecipientTapDriverFixture(activate: false)
        XCTAssertTrue(try sendModifier(56, flags: .maskShift, to: fixture.state))
        XCTAssertTrue(try sendModifier(55, flags: [.maskShift, .maskCommand], to: fixture.state))
        XCTAssertTrue(fixture.bridge.activateProtection())
        XCTAssertTrue(try sendModifier(55, flags: .maskShift, to: fixture.state))
        XCTAssertTrue(try sendModifier(56, flags: [], to: fixture.state))
        XCTAssertTrue(fixture.state.permitsMutation)
        XCTAssertFalse(fixture.bridge.snapshot.handoverRequested)
    }

    @MainActor
    func testOverlappingLeftRightShiftIsConservativeUntilUnambiguousClear() throws {
        let fixture = try RecipientTapDriverFixture(activate: false)
        XCTAssertTrue(try sendModifier(56, flags: .maskShift, to: fixture.state))
        XCTAssertTrue(fixture.bridge.activateProtection())
        XCTAssertFalse(try sendModifier(60, flags: .maskShift, to: fixture.state))
        XCTAssertFalse(try sendModifier(56, flags: .maskShift, to: fixture.state))
        XCTAssertTrue(try sendModifier(60, flags: [], to: fixture.state))
        XCTAssertFalse(fixture.state.permitsMutation)
    }

    @MainActor
    func testMouseTrackingOrPhysicalButtonsPreventArmingBeforeActivation() throws {
        let fixture = try RecipientTapDriverFixture(activate: false)
        XCTAssertTrue(fixture.state.canArmProtection)
        fixture.state.recordPhysicalButtons(released: false)
        XCTAssertFalse(fixture.state.canArmProtection)
        fixture.state.recordPhysicalButtons(released: true)
        XCTAssertTrue(fixture.state.canArmProtection)
        let down = try event(type: .leftMouseDown)
        XCTAssertTrue(fixture.state.observe(type: .leftMouseDown, event: down, isHead: true))
        XCTAssertFalse(fixture.state.canArmProtection)
        let release = try event(type: .leftMouseUp)
        XCTAssertTrue(fixture.state.observe(type: .leftMouseUp, event: release, isHead: true))
        XCTAssertTrue(fixture.state.canArmProtection)
    }

    @MainActor
    func testOwnKeyboardMarkerOnModifierEventCannotBypassRegistryShapeValidation() throws {
        let fixture = try RecipientTapDriverFixture()
        XCTAssertTrue(fixture.bridge.registerBeforePost(isDown: true))
        let event = try fixture.event(isDown: true)
        event.type = .flagsChanged
        XCTAssertFalse(fixture.state.observe(type: .flagsChanged, event: event, isHead: true))
        XCTAssertEqual(fixture.state.snapshot.loss, .eventShapeMismatch)
        XCTAssertEqual(fixture.bridge.drainObservations().ledgerPreventedCount, 0)
        XCTAssertEqual(fixture.bridge.snapshot.ledgerUnresolvedCount, 1)
    }

    @MainActor
    func testClearingCannotIntroduceDeviceOrUnknownBits() throws {
        let bits: [UInt64] = [0x08, 0x10, 0x80, 0x8000]
        for bit in bits {
            let fixture = try RecipientTapDriverFixture()
            let event = try event(type: .flagsChanged, keyCode: 56, flags: CGEventFlags(rawValue: bit))
            XCTAssertEqual(event.flags.rawValue, bit, "Интеграционный тест требует настоящего roundtrip этих bits")
            XCTAssertFalse(fixture.state.observe(type: .flagsChanged, event: event, isHead: true))
            XCTAssertTrue(fixture.bridge.snapshot.handoverRequested)
        }
        // CGEvent может нормализовать старшие неизвестные bits. Чистый classifier всё равно их отвергает.
        XCTAssertFalse(RecipientModifierChange.isClearing(
            keyCode: 56, flags: CGEventFlags(rawValue: 1 << 60), forwarded: []
        ))
        XCTAssertTrue(RecipientModifierChange.isClearing(
            keyCode: 56, flags: [.maskNonCoalesced, .maskNumericPad], forwarded: []
        ))
    }

    @MainActor
    func testCommandDeviceDownBitMustClearEvenWhenGenericBitIsMissing() throws {
        let fixture = try RecipientTapDriverFixture(activate: false)
        let down = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
        XCTAssertTrue(try sendModifier(55, flags: down, to: fixture.state))
        XCTAssertTrue(fixture.bridge.activateProtection())
        XCTAssertFalse(try sendModifier(55, flags: CGEventFlags(rawValue: 0x08), to: fixture.state))
        XCTAssertTrue(try sendModifier(55, flags: [], to: fixture.state))
    }

    @MainActor
    func testMouseDownBetweenIdentityPreflightAndAtomicActivationRefusesWithoutTrappingRelease() throws {
        let fixture = try RecipientTapDriverFixture(activate: false)
        let activation = try XCTUnwrap(fixture.bridge.prepareActivation())
        XCTAssertTrue(fixture.state.observe(type: .leftMouseDown, event: try event(type: .leftMouseDown), isHead: true))
        XCTAssertFalse(fixture.state.activateProtection(activation))
        XCTAssertEqual(fixture.bridge.snapshot.phase, "prepared")
        XCTAssertTrue(fixture.state.observe(type: .leftMouseUp, event: try event(type: .leftMouseUp), isHead: true))
        XCTAssertFalse(fixture.state.activateProtection(activation),
                       "Отвергнутый старый preflight не переиспользуется")
        XCTAssertTrue(fixture.state.activateProtection(try XCTUnwrap(fixture.bridge.prepareActivation())))
        XCTAssertFalse(fixture.state.observe(type: .leftMouseDown,
                                             event: try event(type: .leftMouseDown), isHead: true))
    }

    @MainActor
    func testForeignActivationCannotArmAnotherStateOrConsumeOriginalToken() throws {
        let first = try RecipientTapDriverFixture(activate: false)
        let second = try RecipientTapDriverFixture(activate: false)
        let activation = try XCTUnwrap(first.bridge.prepareActivation())
        second.state.recordPhysicalButtons(released: false)
        XCTAssertFalse(second.state.activateProtection(activation))
        XCTAssertTrue(first.state.activateProtection(activation))
        XCTAssertFalse(first.state.activateProtection(activation))
    }

    @MainActor
    func testDistinctOtherButtonsCannotEraseEachOthersPrearmDebt() throws {
        let fixture = try RecipientTapDriverFixture(activate: false)
        let activation = try XCTUnwrap(fixture.bridge.prepareActivation())
        for button in [3, 4] {
            let down = try event(type: .otherMouseDown)
            down.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            XCTAssertEqual(down.getIntegerValueField(.mouseEventButtonNumber), Int64(button))
            XCTAssertTrue(fixture.state.observe(type: .otherMouseDown, event: down, isHead: true))
        }
        let released = try event(type: .otherMouseUp)
        released.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        XCTAssertTrue(fixture.state.observe(type: .otherMouseUp, event: released, isHead: true))
        XCTAssertFalse(fixture.state.activateProtection(activation))
        released.setIntegerValueField(.mouseEventButtonNumber, value: 4)
        XCTAssertEqual(released.getIntegerValueField(.mouseEventButtonNumber), 4)
        XCTAssertTrue(fixture.state.observe(type: .otherMouseUp, event: released, isHead: true))
        XCTAssertTrue(fixture.state.activateProtection(try XCTUnwrap(fixture.bridge.prepareActivation())))
    }

    @MainActor
    func testUnknownMouseButtonShapeCannotArmOrBeCountedAsAnotherButton() throws {
        for button: Int64 in [-1, 0, 1, 32, Int64.max] {
            XCTAssertNil(RecipientEventKind.otherMouseDown.checkedButtonNumber(button))
        }
        let fixture = try RecipientTapDriverFixture(activate: false)
        let invalid = try event(type: .otherMouseDown)
        invalid.setIntegerValueField(.mouseEventButtonNumber, value: 32)
        XCTAssertFalse(fixture.state.observe(type: .otherMouseDown, event: invalid, isHead: true))
        XCTAssertFalse(fixture.state.canArmProtection)
        XCTAssertEqual(fixture.state.snapshot.loss, .eventShapeMismatch)
    }

    @MainActor
    private func sendModifier(
        _ code: CGKeyCode, flags: CGEventFlags, to state: RecipientTapDriverState
    ) throws -> Bool {
        state.observe(type: .flagsChanged, event: try event(type: .flagsChanged, keyCode: code, flags: flags),
                      isHead: true)
    }

    /// Только объект в RAM: mouse event никуда не отправляется.
    private func event(type: CGEventType, keyCode: CGKeyCode = 0, flags: CGEventFlags = []) throws -> CGEvent {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true))
        event.type = type
        event.flags = flags
        if let button = RecipientEventKind(eventType: type)?.mouseButton {
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        }
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        return event
    }
}
#endif
