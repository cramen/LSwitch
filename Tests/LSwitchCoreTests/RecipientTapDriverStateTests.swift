#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class RecipientTapDriverStateTests: XCTestCase {
    @MainActor
    func testWorkerReadinessDoesNotActivateProtectionOrPermitMutation() throws {
        let fixture = try RecipientTapDriverFixture(activate: false)
        XCTAssertTrue(fixture.state.workerReady)
        XCTAssertFalse(fixture.state.isProtectionAvailable)
        XCTAssertFalse(fixture.state.permitsMutation)
        var called = false
        fixture.state.withProtection { called = true }
        XCTAssertFalse(called)
        XCTAssertTrue(fixture.bridge.activateProtection())
        XCTAssertTrue(fixture.state.isProtectionAvailable)
        XCTAssertTrue(fixture.state.permitsMutation)
    }

    @MainActor
    func testUnknownDownQuarantinesSynchronouslyWhileProtectedDetachRemainsAvailable() throws {
        let fixture = try RecipientTapDriverFixture()
        let event = try fixture.event(isDown: true, owned: false)
        XCTAssertFalse(fixture.state.observe(type: .keyDown, event: event, isHead: true))
        XCTAssertFalse(fixture.state.permitsMutation)
        XCTAssertTrue(fixture.state.isProtectionAvailable)
        XCTAssertTrue(fixture.bridge.snapshot.handoverRequested)
        XCTAssertEqual(fixture.bridge.snapshot.ledgerSubmissionCount, 0)
        let buffer = InputEventBuffer()
        let token = try XCTUnwrap(buffer.beginHold(at: 0))
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: event, at: 1))
        var batch: HeldInputBatch?
        fixture.state.withProtection { batch = buffer.detach(token: token) }
        XCTAssertEqual(batch?.eventCount, 1)
        XCTAssertFalse(buffer.isActive)
        XCTAssertEqual(try XCTUnwrap(batch?.claim()).count, 1)
        XCTAssertNil(batch?.claim())
    }

    @MainActor
    func testUnknownReleasePassesWithoutOwnSubmissionAndWithoutReadingPayload() throws {
        let fixture = try RecipientTapDriverFixture()
        let event = try fixture.event(isDown: false, owned: false)
        event.setIntegerValueField(.keyboardEventKeycode, value: 65_535)
        event.flags = [.maskCommand, .maskAlternate]
        XCTAssertTrue(fixture.state.observe(type: .keyUp, event: event, isHead: true))
        XCTAssertEqual(fixture.bridge.snapshot.ledgerSubmissionCount, 0)
        XCTAssertEqual(fixture.bridge.snapshot.ledgerAdmittedCount, 0)
        XCTAssertTrue(fixture.state.permitsMutation)
        XCTAssertNil(fixture.state.snapshot.loss)
    }

    @MainActor
    func testOwnHeadAdmissionAndTailObservationNeverConfirmReceiverCompletion() throws {
        let fixture = try RecipientTapDriverFixture()
        XCTAssertTrue(fixture.bridge.registerBeforePost(isDown: true))
        let event = try fixture.event(isDown: true)
        XCTAssertTrue(fixture.state.observe(type: .keyDown, event: event, isHead: true))
        XCTAssertTrue(fixture.state.observe(type: .keyDown, event: event, isHead: false))
        XCTAssertEqual(fixture.bridge.snapshot.ledgerAdmittedCount, 0)
        let snapshot = fixture.bridge.drainObservations()
        XCTAssertEqual(snapshot.ledgerAdmittedCount, 1)
        XCTAssertEqual(snapshot.ledgerUnresolvedCount, 1)
        XCTAssertEqual(snapshot.ledgerReturnedCount, 0, "Модель не вызывала реальный post")
        XCTAssertFalse(snapshot.receiverCompleted)
        XCTAssertFalse(snapshot.replayAuthorized)
        XCTAssertEqual(fixture.state.snapshot.observations, [.ownDownAllowed, .ownDownAtTail])
    }

    @MainActor
    func testMalformedOwnReleaseCannotBypassRegistryThroughUnknownEventPath() throws {
        let fixture = try RecipientTapDriverFixture()
        XCTAssertTrue(fixture.bridge.registerBeforePost(isDown: true))
        let event = try fixture.event(isDown: true)
        event.type = .keyUp
        XCTAssertFalse(fixture.state.observe(type: .keyUp, event: event, isHead: true))
        let snapshot = fixture.bridge.drainObservations()
        XCTAssertEqual(snapshot.downStatus, "submitted")
        XCTAssertEqual(snapshot.ledgerPreventedCount, 0)
        XCTAssertEqual(snapshot.ledgerUnresolvedCount, 1)
        XCTAssertTrue(snapshot.handoverRequested)
        XCTAssertEqual(fixture.state.snapshot.observations, [.ownReleaseBlocked])
    }

    @MainActor
    func testClosedGenerationStillAllowsOnlyReleaseOfActuallyAdmittedDown() throws {
        let fixture = try RecipientTapDriverFixture()
        XCTAssertTrue(fixture.bridge.registerBeforePost(isDown: true))
        XCTAssertTrue(fixture.state.observe(type: .keyDown, event: try fixture.event(isDown: true), isHead: true))
        fixture.bridge.closeGeneration()
        XCTAssertFalse(fixture.state.permitsMutation)
        XCTAssertTrue(fixture.state.isProtectionAvailable)
        XCTAssertTrue(fixture.bridge.registerBeforePost(isDown: false))
        XCTAssertTrue(fixture.state.observe(type: .keyUp, event: try fixture.event(isDown: false), isHead: true))
        let snapshot = fixture.bridge.drainObservations()
        XCTAssertEqual(snapshot.ledgerAdmittedCount, 2)
        XCTAssertEqual(snapshot.ledgerUnresolvedCount, 2)
        XCTAssertFalse(snapshot.receiverCompleted)
    }

    @MainActor
    func testDisableNotificationLatchesLossAndLaterPositiveHealthCannotRearm() throws {
        let fixture = try RecipientTapDriverFixture()
        let event = try fixture.event(isDown: true, owned: false)
        XCTAssertTrue(fixture.state.observe(type: .tapDisabledByTimeout, event: event, isHead: true))
        fixture.state.recordHealth(head: true, tail: true, identityMatches: true)
        XCTAssertEqual(fixture.state.snapshot.loss, .tapDisabled)
        XCTAssertEqual(fixture.state.snapshot.disableNotifications, 1)
        XCTAssertFalse(fixture.state.isProtectionAvailable)
        XCTAssertFalse(fixture.state.permitsMutation)
        fixture.state.withProtection { XCTFail("Lost scope не должен detach по старому permit") }
        XCTAssertFalse(fixture.bridge.activateProtection())
    }

    @MainActor
    func testEOFBeforeDrainDoesNotConvertCallbackPreventionIntoLedgerProof() throws {
        let fixture = try RecipientTapDriverFixture()
        XCTAssertTrue(fixture.bridge.registerBeforePost(isDown: true))
        fixture.bridge.closeGeneration()
        XCTAssertFalse(fixture.state.observe(type: .keyDown, event: try fixture.event(isDown: true), isHead: true))
        fixture.state.markLost(.peerEOF)
        let snapshot = fixture.bridge.drainObservations()
        XCTAssertEqual(snapshot.preventedCount, 1)
        XCTAssertEqual(snapshot.ledgerPreventedCount, 0)
        XCTAssertEqual(snapshot.ledgerUnknownCount, 1)
        XCTAssertEqual(snapshot.ledgerUnresolvedCount, 1)
        XCTAssertFalse(fixture.state.isProtectionAvailable)
    }

    @MainActor
    func testLateHealthAndInstallationCannotReviveCleanedWorker() throws {
        let fixture = try RecipientTapDriverFixture()
        fixture.state.recordCleanup()
        fixture.state.recordHealth(head: true, tail: true, identityMatches: true)
        fixture.state.recordInstallation(head: true, tail: true)
        let snapshot = fixture.state.snapshot
        XCTAssertTrue(snapshot.cleanupCompleted)
        XCTAssertFalse(snapshot.workerRunning)
        XCTAssertFalse(snapshot.headEnabled)
        XCTAssertFalse(snapshot.tailEnabled)
        XCTAssertFalse(snapshot.permitsMutation)
    }

    @MainActor
    func testMetadataLimitLatchesLossWithoutKeepingAnUnboundedTrace() throws {
        let fixture = try RecipientTapDriverFixture()
        let event = try fixture.event(isDown: true, owned: false)
        for _ in 0..<(RecipientTapDriverState.maximumObservations + 2) {
            XCTAssertFalse(fixture.state.observe(type: .keyDown, event: event, isHead: true))
        }
        let snapshot = fixture.state.snapshot
        XCTAssertEqual(snapshot.observations.count, RecipientTapDriverState.maximumObservations)
        XCTAssertEqual(snapshot.headBlocked, RecipientTapDriverState.maximumObservations)
        XCTAssertTrue(snapshot.observationsTruncated)
        XCTAssertEqual(snapshot.loss, .observationLimit)
        XCTAssertFalse(snapshot.protectionAvailable)
    }

    @MainActor
    func testSenderHeaderIsComparedWithSenderAndNotWithDistinctRecipientPID() throws {
        let own = try XCTUnwrap(RecoveryRecipientProbeBridge.makeOwnProcess())
        let sender = own.capturedSenderIdentity
        let target = try XCTUnwrap(RecoveryProcessIdentity(processID: .max, birthSeconds: 99, birthMicroseconds: 0))
        let ledger = ConversionSafetyLedger(generation: 1)
        let gate = try XCTUnwrap(RecipientGateState(scope: .init(operation: ledger.operation, target: target)))
        let bridge = try XCTUnwrap(RecoveryRecipientProbeBridge(
            sender: sender, target: target, ledger: ledger, gate: gate, identityCheck: { _ in true }
        ))
        XCTAssertTrue(bridge.preparePair(keyCode: 0, downFlags: 0, releaseFlags: 0))
        XCTAssertTrue(bridge.activateProtection())
        XCTAssertTrue(bridge.registerBeforePost(isDown: true))
        let state = RecipientTapDriverState(bridge: bridge)
        state.recordInstallation(head: true, tail: true)
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: try XCTUnwrap(bridge.marker(isDown: true)))
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUnixProcessID), Int64(sender.processID))
        XCTAssertTrue(state.observe(type: .keyDown, event: event, isHead: true))
        XCTAssertEqual(bridge.drainObservations().ledgerAdmittedCount, 1)
        XCTAssertNil(RecipientTapDriver(bridge: bridge), "Настоящий driver не принимает вымышленный target birth")
    }
}
#endif
