#if DEBUG
import CoreGraphics
import Darwin
import Foundation
@testable import LSwitchCore
import XCTest

final class NativeModifierAdmissionTests: XCTestCase {
    @MainActor
    func testBothSidesOfSupportedModifiersPreserveExactHeaderFlags() throws {
        let modifiers: [(UInt16, CGEventFlags)] = [
            (54, .maskCommand), (55, .maskCommand), (56, .maskShift), (60, .maskShift),
            (58, .maskAlternate), (61, .maskAlternate), (59, .maskControl), (62, .maskControl)
        ]
        for (code, flag) in modifiers {
            let event = try packet(keyCode: code, flags: [flag, .maskAlphaShift], marker: 0)
            XCTAssertEqual(NativeDispatchShape.readKeyboard(event),
                           .init(phase: .modifierDown, keyCode: code, modifierFlags: event.flags.rawValue))
            event.flags = .maskAlphaShift
            XCTAssertEqual(NativeDispatchShape.readKeyboard(event),
                           .init(phase: .modifierUp, keyCode: code, modifierFlags: event.flags.rawValue))
        }
        let unsupported = try packet(keyCode: 57, flags: .maskAlphaShift, marker: 0)
        XCTAssertNil(NativeDispatchShape.readKeyboard(unsupported))
        unsupported.type = .leftMouseDown
        XCTAssertNil(NativeDispatchShape.readKeyboard(unsupported))
    }

    @MainActor
    func testAdmittedModifierReleaseSurvivesGenerationCloseWithoutRendererCompletion() throws {
        let fixture = try Fixture()
        let down = try XCTUnwrap(fixture.ledger.willSubmit(.modifier, operation: fixture.scope.operation))
        XCTAssertTrue(fixture.gate.registerSubmitted(fixture.pair.down, token: down, scope: fixture.scope))
        let first = try packet(keyCode: 55, flags: .maskCommand, marker: fixture.pair.down.marker)
        XCTAssertTrue(fixture.state.observe(type: .flagsChanged, event: first, isHead: true))
        XCTAssertTrue(fixture.state.observe(type: .flagsChanged, event: first, isHead: false))
        fixture.gate.closeGeneration()
        let release = try XCTUnwrap(fixture.ledger.willSubmitCleanup(
            .balancingRelease, operation: fixture.scope.operation))
        XCTAssertTrue(fixture.gate.registerSubmitted(fixture.pair.release, token: release, scope: fixture.scope))
        let last = try packet(keyCode: 55, flags: [], marker: fixture.pair.release.marker)
        XCTAssertTrue(fixture.state.observe(type: .flagsChanged, event: last, isHead: true))
        XCTAssertTrue(fixture.state.observe(type: .flagsChanged, event: last, isHead: false))
        let report = fixture.bridge.drainObservations()
        XCTAssertEqual(report.ledgerAdmittedCount, 2)
        XCTAssertTrue(fixture.ledger.hasUnresolvedSubmissions)
        XCTAssertFalse(fixture.ledger.permitsConfirmedResult)
        XCTAssertEqual(fixture.state.snapshot.tailObserved, 2)
        XCTAssertNil(fixture.state.snapshot.loss)
    }

    @MainActor
    func testWrongModifierFlagsBlockBeforeAdmissionAndDoNotAuthorizeRelease() throws {
        let fixture = try Fixture()
        let down = try XCTUnwrap(fixture.ledger.willSubmit(.modifier, operation: fixture.scope.operation))
        XCTAssertTrue(fixture.gate.registerSubmitted(fixture.pair.down, token: down, scope: fixture.scope))
        let wrong = try packet(keyCode: 55, flags: .maskShift, marker: fixture.pair.down.marker)
        XCTAssertFalse(fixture.state.observe(type: .flagsChanged, event: wrong, isHead: true))
        XCTAssertFalse(fixture.state.permitsMutation)
        let release = try XCTUnwrap(fixture.ledger.willSubmitCleanup(
            .balancingRelease, operation: fixture.scope.operation))
        XCTAssertFalse(fixture.gate.registerSubmitted(fixture.pair.release, token: release, scope: fixture.scope))
        XCTAssertEqual(fixture.bridge.drainObservations().ledgerAdmittedCount, 0)
        XCTAssertTrue(fixture.ledger.hasUnresolvedSubmissions)
    }

    @MainActor
    func testUnsupportedOwnModifierMarksDriverLostInsteadOfBecomingUserInput() throws {
        let fixture = try Fixture()
        let event = try packet(keyCode: 57, flags: .maskAlphaShift, marker: fixture.pair.down.marker)
        XCTAssertFalse(fixture.state.observe(type: .flagsChanged, event: event, isHead: true))
        XCTAssertEqual(fixture.state.snapshot.loss, .eventShapeMismatch)
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
    }

    private func packet(keyCode: UInt16, flags: CGEventFlags, marker: Int64) throws -> CGEvent {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        source.userData = marker
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true))
        event.type = .flagsChanged
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), marker)
        return event
    }

    @MainActor
    private final class Fixture {
        let ledger = ConversionSafetyLedger(generation: 1)
        let scope: RecoveryOperationTarget
        let gate: RecipientGateState
        let bridge: RecoveryRecipientProbeBridge
        let state: RecipientTapDriverState
        let pair: NativeDispatchPairReservation

        init() throws {
            let process = try XCTUnwrap(SystemProcessIdentity.read(processID: getpid()))
            scope = .init(operation: ledger.operation, target: process)
            gate = try XCTUnwrap(RecipientGateState(scope: scope))
            let shape = NativeDispatchPairShape(
                down: .init(phase: .modifierDown, keyCode: 55, modifierFlags: CGEventFlags.maskCommand.rawValue),
                release: .init(phase: .modifierUp, keyCode: 55, modifierFlags: 0))
            pair = try XCTUnwrap(gate.reservePairs([shape], scope: scope)?.first)
            bridge = try XCTUnwrap(RecoveryRecipientProbeBridge(sender: process, target: process,
                                                               ledger: ledger, gate: gate))
            state = RecipientTapDriverState(bridge: bridge)
            state.recordInstallation(head: true, tail: true)
            XCTAssertTrue(bridge.activateProtection())
        }
    }
}
#endif
