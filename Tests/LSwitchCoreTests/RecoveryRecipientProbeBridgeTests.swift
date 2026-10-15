#if DEBUG
import Darwin
@testable import LSwitchCore
import XCTest

/// Только модель callback-протокола. Здесь нет CGEvent, post, tap, UI или доказательства системного nil-return.
final class RecoveryRecipientProbeBridgeTests: XCTestCase {
    @MainActor
    func testCloseBeforeActivationNeverReportsProtectionAvailable() throws {
        let bridge = try XCTUnwrap(RecoveryRecipientProbeBridge.makeOwnProcess())
        XCTAssertEqual(bridge.processID, getpid())
        bridge.closeGeneration()
        let snapshot = bridge.snapshot
        XCTAssertEqual(snapshot.phase, "closed")
        XCTAssertFalse(snapshot.protectionAvailable)
        XCTAssertFalse(bridge.activateProtection())
        XCTAssertFalse(bridge.preparePair(keyCode: 0, downFlags: 0, releaseFlags: 0))
        XCTAssertEqual(snapshot.ledgerSubmissionCount, 0)
        XCTAssertEqual(snapshot.preventedCount, 0)
        XCTAssertEqual(snapshot.ledgerPreventedCount, 0)
        XCTAssertFalse(snapshot.recoveryGateAccepted)
    }

    @MainActor
    func testPairPreparationDoesNotCreateAnySubmissionOrAdmission() throws {
        let bridge = try XCTUnwrap(RecoveryRecipientProbeBridge.makeOwnProcess())
        XCTAssertNil(bridge.marker(isDown: true))
        XCTAssertTrue(bridge.preparePair(keyCode: 0, downFlags: 0, releaseFlags: 0))
        let down = try XCTUnwrap(bridge.marker(isDown: true))
        let release = try XCTUnwrap(bridge.marker(isDown: false))
        XCTAssertNotEqual(down, release)
        XCTAssertTrue(bridge.activateProtection())
        let snapshot = bridge.drainObservations()
        XCTAssertEqual(snapshot.reservationCount, 2)
        XCTAssertEqual(snapshot.preparedCount, 2)
        XCTAssertEqual(snapshot.submittedCount, 0)
        XCTAssertEqual(snapshot.admittedCount, 0)
        XCTAssertEqual(snapshot.preventedCount, 0)
        XCTAssertEqual(snapshot.ledgerSubmissionCount, 0)
        XCTAssertEqual(snapshot.ledgerReturnedCount, 0)
        XCTAssertEqual(snapshot.ledgerUnresolvedCount, 0)
        XCTAssertFalse(snapshot.receiverCompleted)
        XCTAssertFalse(snapshot.replayAuthorized)
    }

    @MainActor
    func testForeignSourceAndUnknownMarkerCannotBecomeAdmissionOrLedgerClosure() throws {
        for foreignSource in [true, false] {
            let bridge = try submittedBridge()
            let reserved = try XCTUnwrap(bridge.marker(isDown: true))
            let sender = Int64(bridge.processID) + (foreignSource ? 1 : 0)
            let marker = foreignSource ? reserved : 0
            XCTAssertFalse(bridge.owns(senderPID: sender, marker: marker))
            // Shape — заранее заданные числа fixture, а не чтение непризнанного CGEvent.
            let decision = bridge.observeOwn(senderPID: sender, marker: marker, phase: .keyDown,
                                             keyCode: 0, modifierFlags: 0)
            XCTAssertFalse(decision.allowsEvent)
            XCTAssertEqual(decision.admission, "header_rejected")
            bridge.recordCallbackReturn(decision, returnedNil: true)
            let snapshot = bridge.drainObservations()
            XCTAssertTrue(snapshot.lost)
            XCTAssertEqual(snapshot.downStatus, "submitted")
            XCTAssertEqual(snapshot.admittedCount, 0)
            XCTAssertEqual(snapshot.preventedCount, 0)
            XCTAssertEqual(snapshot.ledgerAdmittedCount, 0)
            XCTAssertEqual(snapshot.ledgerPreventedCount, 0)
            XCTAssertEqual(snapshot.ledgerUnresolvedCount, 1)
            XCTAssertEqual(snapshot.ledgerReturnedCount, 0)
            XCTAssertGreaterThan(foreignSource ? snapshot.sourceRejectedCount : snapshot.markerRejectedCount, 0)
        }
    }

    @MainActor
    func testMismatchedCallbackReturnLatchesLossWithoutFalseLedgerPrevention() throws {
        let bridge = try submittedBridge()
        bridge.closeGeneration()
        let decision = try observeDown(bridge)
        XCTAssertFalse(decision.allowsEvent)
        XCTAssertEqual(decision.admission, "prevented")
        // Нарушение адаптера: Core требует nil, но смоделирован возврат события.
        bridge.recordCallbackReturn(decision, returnedNil: false)
        let snapshot = bridge.drainObservations()
        XCTAssertTrue(snapshot.lost)
        XCTAssertEqual(snapshot.callbackMismatchCount, 1)
        XCTAssertEqual(snapshot.preventedCount, 1, "Это только решение Core, а не закрытие ledger")
        XCTAssertEqual(snapshot.ledgerPreventedCount, 0)
        XCTAssertEqual(snapshot.ledgerUnresolvedCount, 1)
        XCTAssertEqual(snapshot.pendingObservationCount, 0)
        XCTAssertFalse(snapshot.protectionAvailable)
        XCTAssertFalse(snapshot.replayAuthorized)
    }

    @MainActor
    func testLossBeforeDrainCannotPromoteRegistryPreventionToLedgerClosure() throws {
        let bridge = try submittedBridge()
        bridge.closeGeneration()
        let decision = try observeDown(bridge)
        XCTAssertTrue(decision.protectionAvailable)
        bridge.recordCallbackReturn(decision, returnedNil: true)
        XCTAssertEqual(bridge.snapshot.pendingObservationCount, 1)
        XCTAssertEqual(bridge.snapshot.ledgerPreventedCount, 0)
        bridge.markLost()
        let snapshot = bridge.drainObservations()
        XCTAssertTrue(snapshot.lost)
        XCTAssertEqual(snapshot.preventedCount, 1)
        XCTAssertEqual(snapshot.ledgerPreventedCount, 0)
        XCTAssertEqual(snapshot.ledgerUnknownCount, 1)
        XCTAssertEqual(snapshot.ledgerUnresolvedCount, 1)
        XCTAssertEqual(snapshot.pendingObservationCount, 0)
        XCTAssertFalse(snapshot.receiverCompleted)
        XCTAssertFalse(snapshot.recoveryGateAccepted)
    }

    @MainActor
    private func submittedBridge() throws -> RecoveryRecipientProbeBridge {
        let bridge = try XCTUnwrap(RecoveryRecipientProbeBridge.makeOwnProcess())
        XCTAssertEqual(bridge.processID, getpid())
        XCTAssertTrue(bridge.preparePair(keyCode: 0, downFlags: 0, releaseFlags: 0))
        XCTAssertTrue(bridge.activateProtection())
        // Только модель pre-post регистрации: recordPostReturned не вызывается, реального post нет.
        XCTAssertTrue(bridge.registerBeforePost(isDown: true))
        return bridge
    }

    private func observeDown(_ bridge: RecoveryRecipientProbeBridge) throws -> RecoveryRecipientProbeDecision {
        let marker = try XCTUnwrap(bridge.marker(isDown: true))
        let sender = Int64(bridge.processID)
        XCTAssertTrue(bridge.owns(senderPID: sender, marker: marker))
        return bridge.observeOwn(senderPID: sender, marker: marker, phase: .keyDown,
                                 keyCode: 0, modifierFlags: 0)
    }
}
#endif
