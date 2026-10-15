import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryCoordinatorTests: XCTestCase {
    @MainActor
    func testReservationAndPendingRecordExcludeAnotherOperationAndClaimBatchOnce() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        let next = ConversionSafetyLedger(generation: 2)
        XCTAssertNil(fixture.coordinator.reserve(operation: next.operation, target: fixture.target))
        XCTAssertEqual(try hold.append("a"), .accepted)
        XCTAssertEqual(try hold.append("😀", type: .keyUp), .accepted)
        let transfer = try hold.handover()
        let claim = try fixture.claim()
        let result = fixture.coordinator.adopt(transfer.batch, sealed: transfer.sealed,
                                               claim: claim, reason: .cleanupUnconfirmed)
        guard case .adopted(let identifier) = result else { XCTFail("Нет владельца recovery"); return }
        let metadata = try XCTUnwrap(fixture.coordinator.metadata)
        XCTAssertEqual(metadata.identifier, identifier)
        XCTAssertEqual(metadata.binding, hold.binding)
        XCTAssertEqual(metadata.eventCount, 2)
        XCTAssertEqual(metadata.utf16Bytes, 6)
        XCTAssertFalse(metadata.payloadDeleted)
        XCTAssertTrue(metadata.isVisible)
        XCTAssertNil(transfer.batch.claim())
        hold.buffer.end { _ in XCTFail("Исходный владелец уже не имеет событий для replay") }
        XCTAssertEqual(fixture.coordinator.adopt(transfer.batch, sealed: transfer.sealed,
                                                claim: claim, reason: .cleanupUnconfirmed),
                       .rejected(.noReservation))
        XCTAssertEqual(fixture.coordinator.metadata, metadata)
        XCTAssertNil(fixture.coordinator.reserve(operation: next.operation, target: fixture.target))
    }

    @MainActor
    func testAdoptionWithWrongClaimDoesNotConsumeBatch() throws {
        for foreignOperation in [false, true] {
            let fixture = try RecoveryTestFixture()
            let hold = try fixture.begin()
            XCTAssertEqual(try hold.append(), .accepted)
            let transfer = try hold.handover()
            let claim: ConversionSafetyInputClaim
            if foreignOperation {
                claim = try RecoveryTestFixture().claim()
            } else {
                claim = try fixture.claim(recovery: false)
            }
            XCTAssertEqual(fixture.coordinator.adopt(transfer.batch, sealed: transfer.sealed,
                                                    claim: claim, reason: .cleanupUnconfirmed),
                           .rejected(.wrongBinding))
            XCTAssertEqual(try XCTUnwrap(transfer.batch.claim()).count, 1)
            XCTAssertFalse(fixture.coordinator.hasPendingRecovery)
        }
    }

    @MainActor
    func testForeignBufferWithEqualGenerationDoesNotReplacePreparedQueue() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append(), .accepted)
        let transfer = try hold.handover()
        let other = try RecoveryTestFixture()
        let otherHold = try other.begin()
        XCTAssertEqual(try otherHold.append(), .accepted)
        let foreign = try otherHold.handover()
        XCTAssertEqual(foreign.batch.generation, transfer.batch.generation)
        XCTAssertEqual(fixture.coordinator.adopt(foreign.batch, sealed: transfer.sealed,
                                                claim: try fixture.claim(), reason: .cleanupUnconfirmed),
                       .rejected(.wrongBinding))
        XCTAssertEqual(try XCTUnwrap(foreign.batch.claim()).count, 1)
        XCTAssertEqual(try XCTUnwrap(transfer.batch.claim()).count, 1)
    }

    @MainActor
    func testCountMismatchAndAlreadyClaimedBatchCannotBeAdopted() throws {
        for consumeFirst in [false, true] {
            let fixture = try RecoveryTestFixture()
            let hold = try fixture.begin()
            XCTAssertEqual(try hold.append(), .accepted)
            if !consumeFirst {
                XCTAssertEqual(hold.admission.admit(utf16Units: 1, binding: hold.binding) { true }, .accepted)
            }
            let transfer = try hold.handover()
            if consumeFirst { XCTAssertEqual(try XCTUnwrap(transfer.batch.claim()).count, 1) }
            XCTAssertEqual(fixture.coordinator.adopt(transfer.batch, sealed: transfer.sealed,
                                                    claim: try fixture.claim(), reason: .cleanupUnconfirmed),
                           .rejected(consumeFirst ? .alreadyClaimed : .countMismatch))
            XCTAssertNil(fixture.coordinator.metadata)
            if !consumeFirst { XCTAssertEqual(try XCTUnwrap(transfer.batch.claim()).count, 1) }
        }
    }

    @MainActor
    func testGateLossAndOffBeforeHandoverStillPreserveAcceptedPrefix() throws {
        for stop in [false, true] {
            let fixture = try RecoveryTestFixture()
            let hold = try fixture.begin()
            XCTAssertEqual(try hold.append("saved"), .accepted)
            if stop { fixture.coordinator.setEnabled(false) } else { fixture.coordinator.permissionsLost() }
            fixture.gate.setAvailable(false)
            XCTAssertFalse(hold.admission.permitsMutation(for: hold.binding))
            XCTAssertEqual(try hold.append("not saved"), .rejected(stop ? .interceptionStopped : .gateUnavailable))
            let identifier = try fixture.adopt(hold)
            XCTAssertEqual(fixture.coordinator.metadata?.identifier, identifier)
            XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
            XCTAssertEqual(fixture.coordinator.metadata?.utf16Bytes, 10)
            XCTAssertEqual(fixture.coordinator.metadata?.protection, stop ? .interceptionOff : .unavailable)
        }
    }

    @MainActor
    func testOffHideSecureAndLatePermissionReturnDoNotDeleteOrReplay() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append("saved"), .accepted)
        let identifier = try fixture.adopt(hold)
        fixture.coordinator.hide()
        fixture.coordinator.setEnabled(false)
        fixture.coordinator.secureInputBegan()
        fixture.coordinator.permissionsLost()
        fixture.gate.setAvailable(true)
        fixture.coordinator.permissionsRestored()
        fixture.coordinator.setEnabled(true)
        let metadata = try XCTUnwrap(fixture.coordinator.metadata)
        XCTAssertEqual(metadata.identifier, identifier)
        XCTAssertEqual(metadata.eventCount, 1)
        XCTAssertEqual(metadata.utf16Bytes, 10)
        XCTAssertFalse(metadata.payloadDeleted)
        XCTAssertFalse(metadata.isVisible)
        XCTAssertEqual(metadata.protection, .unavailable)
        XCTAssertNil(fixture.coordinator.reserve(operation: fixture.ledger.operation, target: fixture.target))
        fixture.coordinator.show()
        XCTAssertEqual(fixture.coordinator.metadata?.isVisible, true)
        fixture.coordinator.secureInputEnded()
        XCTAssertEqual(fixture.coordinator.metadata?.protection, .unverified)
    }

    @MainActor
    func testSecureAndPermissionLifecycleRefusePreparationWithoutResumingOldAdmission() throws {
        let fixture = try RecoveryTestFixture()
        fixture.coordinator.secureInputBegan()
        XCTAssertNil(fixture.coordinator.reserve(operation: fixture.ledger.operation, target: fixture.target))
        XCTAssertEqual(fixture.gate.preparationCount, 0)
        fixture.coordinator.permissionsRestored()
        XCTAssertNil(fixture.coordinator.reserve(operation: fixture.ledger.operation, target: fixture.target))
        fixture.coordinator.secureInputEnded()
        fixture.coordinator.permissionsLost()
        XCTAssertNil(fixture.coordinator.reserve(operation: fixture.ledger.operation, target: fixture.target))
        fixture.coordinator.permissionsRestored()
        let hold = try fixture.begin()
        fixture.coordinator.permissionsLost()
        fixture.coordinator.permissionsRestored()
        XCTAssertFalse(hold.admission.permitsMutation(for: hold.binding))
        XCTAssertEqual(try hold.append(), .rejected(.gateUnavailable))
        try fixture.adopt(hold)
        XCTAssertTrue(fixture.coordinator.hasPendingRecovery)
    }

    @MainActor
    func testEmptyDangerousQueueStillNeedsRecoveryAndQuitDecision() throws {
        let fixture = try RecoveryTestFixture()
        let identifier = try fixture.adopt(fixture.begin())
        XCTAssertTrue(fixture.coordinator.hasPendingRecovery)
        XCTAssertEqual(fixture.coordinator.metadata?.identifier, identifier)
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 0)
        XCTAssertEqual(fixture.coordinator.metadata?.payloadDeleted, false)
        guard case .confirmationRequired = fixture.coordinator.requestQuit() else {
            XCTFail("Пустая очередь не доказывает безопасность оставленного выделения")
            return
        }
    }

    @MainActor
    func testExplicitDeletionIsIdempotentAndDoesNotClearDangerousTarget() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append(), .accepted)
        let identifier = try fixture.adopt(hold)
        let intent = try XCTUnwrap(fixture.coordinator.requestDeletion())
        fixture.coordinator.hide()
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
        XCTAssertEqual(fixture.coordinator.confirmDeletion(intent), .deleted)
        XCTAssertEqual(fixture.coordinator.confirmDeletion(intent), .deleted)
        XCTAssertEqual(fixture.coordinator.metadata?.identifier, identifier)
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 0)
        XCTAssertEqual(fixture.coordinator.metadata?.payloadDeleted, true)
        XCTAssertTrue(fixture.coordinator.hasPendingRecovery)
        XCTAssertNil(fixture.coordinator.reserve(operation: fixture.ledger.operation, target: fixture.target))
        guard case .confirmationRequired = fixture.coordinator.requestQuit() else {
            XCTFail("Удаление payload не снимает неподтверждённую цель")
            return
        }
    }

    @MainActor
    func testQuitCancelAndDeleteChoicesAreSingleUseAndNeverReplay() throws {
        let fixture = try RecoveryTestFixture()
        XCTAssertEqual(fixture.coordinator.requestQuit(), .allowed)
        let hold = try fixture.begin()
        XCTAssertEqual(fixture.coordinator.requestQuit(), .handoverRequired)
        XCTAssertEqual(try hold.append(), .accepted)
        try fixture.adopt(hold)
        guard case .confirmationRequired(let first) = fixture.coordinator.requestQuit() else {
            XCTFail("Нужно решение по очереди"); return
        }
        XCTAssertEqual(fixture.coordinator.decideQuit(first, choice: .stay), .stay)
        XCTAssertEqual(fixture.coordinator.decideQuit(first, choice: .deleteAndQuit), .stay)
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
        guard case .confirmationRequired(let second) = fixture.coordinator.requestQuit() else {
            XCTFail("Повторный quit требует нового решения"); return
        }
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(fixture.coordinator.decideQuit(second, choice: .deleteAndQuit), .quitAllowed)
        XCTAssertEqual(fixture.coordinator.decideQuit(second, choice: .deleteAndQuit), .quitAllowed)
        XCTAssertEqual(fixture.coordinator.confirmDeletion(second), .stale)
        XCTAssertEqual(fixture.coordinator.metadata?.payloadDeleted, true)
        XCTAssertTrue(fixture.coordinator.hasPendingRecovery)
    }

    @MainActor
    func testForeignAndSupersededUserIntentsDoNotDeleteCurrentPayload() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append(), .accepted)
        try fixture.adopt(hold)
        let old = try XCTUnwrap(fixture.coordinator.requestDeletion())
        guard case .confirmationRequired = fixture.coordinator.requestQuit() else { XCTFail("Нет quit intent"); return }
        XCTAssertEqual(fixture.coordinator.confirmDeletion(old), .stale)
        let foreign = try RecoveryTestFixture()
        try foreign.adopt(foreign.begin())
        let other = try XCTUnwrap(foreign.coordinator.requestDeletion())
        XCTAssertEqual(fixture.coordinator.confirmDeletion(other), .stale)
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
        XCTAssertEqual(fixture.coordinator.metadata?.payloadDeleted, false)
    }

    @MainActor
    func testCancelledDeletionRejectsLateConfirmAndRequiresFreshDecision() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append(), .accepted)
        try fixture.adopt(hold)
        let cancelled = try XCTUnwrap(fixture.coordinator.requestDeletion())
        XCTAssertEqual(fixture.coordinator.cancelDeletion(cancelled), .stay)
        XCTAssertEqual(fixture.coordinator.confirmDeletion(cancelled), .stay)
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
        let fresh = try XCTUnwrap(fixture.coordinator.requestDeletion())
        XCTAssertNotEqual(fresh, cancelled)
        XCTAssertEqual(fixture.coordinator.confirmDeletion(fresh), .deleted)
        XCTAssertEqual(fixture.coordinator.confirmDeletion(cancelled), .stale)
    }

    @MainActor
    func testOrdinaryCompletionFreesReservationOnlyAfterMatchingClaim() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append(), .accepted)
        let sealed = try XCTUnwrap(hold.admission.seal(binding: hold.binding))
        let foreignClaim = try RecoveryTestFixture().claim()
        XCTAssertFalse(fixture.coordinator.completeOrdinary(sealed: sealed, claim: foreignClaim))
        var delivered = 0
        XCTAssertTrue(hold.buffer.end(token: hold.binding.hold) { _ in delivered += 1 })
        XCTAssertEqual(delivered, 1)
        let claim = try fixture.claim(recovery: false)
        XCTAssertTrue(fixture.coordinator.completeOrdinary(sealed: sealed, claim: claim))
        XCTAssertFalse(fixture.coordinator.completeOrdinary(sealed: sealed, claim: claim))
        XCTAssertFalse(fixture.coordinator.hasPendingRecovery)
        let next = ConversionSafetyLedger(generation: 2)
        XCTAssertNotNil(fixture.coordinator.reserve(operation: next.operation, target: fixture.target))
    }
}
