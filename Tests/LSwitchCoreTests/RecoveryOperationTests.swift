import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryOperationTests: XCTestCase {
    @MainActor
    func testDefaultHandoverUnavailableRefusesBeforeBindingOrCapturePublication() throws {
        let fixture = try RecoveryTestFixture()
        let admission = try XCTUnwrap(fixture.coordinator.reserve(
            operation: fixture.ledger.operation, target: fixture.target
        ))
        XCTAssertNil(RecoveryOperation.prepare(
            ledger: fixture.ledger, admission: admission, tapIdentifier: UUID(), at: 0
        ))
        XCTAssertTrue(fixture.coordinator.abandonBeforeHold(admission))
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
    }

    @MainActor
    func testApplicationOwnerRetainsOrderedQueueAfterTapOwnerIsDestroyed() throws {
        let fixture = try RecoveryOperationFixture()
        var tap: RecoveryTestTapOwner? = RecoveryTestTapOwner(port: fixture.operation.capturePort)
        weak var oldTap = tap
        XCTAssertEqual(try fixture.append("first"), .accepted)
        XCTAssertEqual(try fixture.append("😀"), .accepted)
        tap = nil
        XCTAssertNil(oldTap)
        XCTAssertFalse(fixture.operation.capturePort.permitsMutation(for: fixture.operation.capturePort.scope))
        XCTAssertEqual(try fixture.append("late"), .rejected(.interceptionStopped))
        XCTAssertEqual(fixture.operation.closeCapture(), .detached(.init(events: 2, utf16Bytes: 14)))
        fixture.finishRecovery()
        guard case .adopted = fixture.operation.adopt(in: fixture.coordinator, reason: .interceptionStopped) else {
            return XCTFail("Внешний владелец должен сохранить очередь после deinit tap")
        }
        XCTAssertEqual(try fixture.revealedTexts(), ["first", "😀"])
    }

    @MainActor
    func testUnavailableProtectionKeepsSealedQueueUntilGuardedDetachAndRejectedAdoptKeepsBatch() throws {
        let fixture = try RecoveryOperationFixture()
        XCTAssertEqual(try fixture.append("kept"), .accepted)
        fixture.gate.setAvailable(false)
        let counts = RecoveryAdmissionCounts(events: 1, utf16Bytes: 8)
        XCTAssertEqual(fixture.operation.closeCapture(), .awaitingProtection(counts))
        XCTAssertEqual(try fixture.append("new"), .rejected(.closed))
        fixture.finishRecovery()
        XCTAssertEqual(fixture.operation.adopt(in: fixture.coordinator, reason: .gateLost), .awaitingDetach)
        fixture.gate.setAvailable(true)
        XCTAssertEqual(fixture.operation.closeCapture(), .detached(counts))
        XCTAssertEqual(fixture.operation.adopt(in: RecoveryCoordinator(), reason: .gateLost), .rejected(.noReservation))
        XCTAssertEqual(fixture.ledger.inputOwner, .recovery)
        guard case .adopted(let identifier) = fixture.operation.adopt(in: fixture.coordinator, reason: .gateLost) else {
            return XCTFail("Rejected adopt не должен claim или удалить batch")
        }
        XCTAssertEqual(fixture.operation.adopt(in: fixture.coordinator, reason: .gateLost), .adopted(identifier))
        XCTAssertEqual(fixture.operation.closeCapture(), .transferred(identifier))
        XCTAssertNil(fixture.ledger.claimInput(operation: fixture.ledger.operation))
        XCTAssertEqual(try fixture.revealedTexts(), ["kept"])
    }

    @MainActor
    func testForeignTapHoldAndOperationScopesCannotCaptureInvalidateExpireOrDetach() throws {
        let fixture = try RecoveryOperationFixture()
        let other = try RecoveryOperationFixture()
        let port = fixture.operation.capturePort
        let own = port.scope
        XCTAssertEqual(own.binding.hold.generation, other.operation.capturePort.scope.binding.hold.generation)
        let foreignScopes = [
            other.operation.capturePort.scope,
            RecoveryCaptureScope(binding: own.binding, tapIdentifier: UUID()),
            RecoveryCaptureScope(binding: .init(scope: own.binding.scope,
                                               hold: other.operation.capturePort.scope.binding.hold),
                                 tapIdentifier: own.tapIdentifier)
        ]
        for foreign in foreignScopes {
            XCTAssertEqual(port.capture(try RecoveryOperationFixture.event("x"), utf16Units: 1,
                                        from: foreign, at: 1), .rejected(.wrongBinding))
            XCTAssertFalse(port.invalidate(.interceptionStopped, scope: foreign))
            XCTAssertFalse(port.expire(scope: foreign, at: .max))
            XCTAssertEqual(port.close(scope: foreign), .wrongScope)
        }
        XCTAssertTrue(port.permitsMutation(for: own))
        XCTAssertEqual(try fixture.append(), .accepted)
        XCTAssertEqual(fixture.operation.closeCapture(), .detached(.init(events: 1, utf16Bytes: 2)))
    }

    @MainActor
    func testExpiredLeaseLatchesWithoutAutomaticDetachOrNewCapture() throws {
        let fixture = try RecoveryOperationFixture()
        let port = fixture.operation.capturePort
        XCTAssertEqual(try fixture.append(), .accepted)
        XCTAssertFalse(port.expire(scope: port.scope, at: InputEventBuffer.maximumDuration - 1))
        XCTAssertTrue(port.expire(scope: port.scope, at: InputEventBuffer.maximumDuration))
        XCTAssertEqual(try fixture.append("later", at: 1), .rejected(.closed))
        fixture.finishRecovery()
        XCTAssertEqual(fixture.operation.adopt(in: fixture.coordinator, reason: .admissionStopped), .awaitingDetach)
        XCTAssertEqual(fixture.operation.closeCapture(), .detached(.init(events: 1, utf16Bytes: 2)))
    }

    @MainActor
    func testEmptyQueueStillRequiresProtectedDetachForUnknownMutation() throws {
        let fixture = try RecoveryOperationFixture()
        let submission = try XCTUnwrap(fixture.ledger.willSubmit(.selection, operation: fixture.ledger.operation))
        fixture.ledger.observe(.unknown, for: submission)
        fixture.finishRecovery()
        fixture.gate.setAvailable(false)
        XCTAssertEqual(fixture.operation.closeCapture(), .awaitingProtection(.init(events: 0, utf16Bytes: 0)))
        XCTAssertEqual(fixture.operation.adopt(in: fixture.coordinator, reason: .cleanupUnconfirmed), .awaitingDetach)
        fixture.gate.setAvailable(true)
        XCTAssertEqual(fixture.operation.closeCapture(), .detached(.init(events: 0, utf16Bytes: 0)))
        guard case .adopted = fixture.operation.adopt(in: fixture.coordinator, reason: .cleanupUnconfirmed) else {
            return XCTFail("Пустая очередь не отменяет опасное выделение")
        }
        XCTAssertTrue(fixture.coordinator.hasPendingRecovery)
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 0)
    }

    @MainActor
    func testOrdinaryDecisionDoesNotInventReplayPermitOrTransferQueue() throws {
        let fixture = try RecoveryOperationFixture()
        XCTAssertEqual(try fixture.append(), .accepted)
        XCTAssertEqual(fixture.operation.adopt(in: fixture.coordinator, reason: .admissionStopped), .awaitingDecision)
        XCTAssertNotNil(fixture.ledger.finish(operation: fixture.ledger.operation, text: .unchangedByOperation,
                                            cleanup: .noOwnedMutation, ordinaryRouteValid: true))
        XCTAssertEqual(fixture.operation.closeCapture(), .detached(.init(events: 1, utf16Bytes: 2)))
        XCTAssertEqual(fixture.operation.adopt(in: fixture.coordinator, reason: .admissionStopped),
                       .ordinaryDeliveryUnavailable)
        XCTAssertEqual(fixture.ledger.inputOwner, .transaction)
        XCTAssertFalse(fixture.coordinator.hasPendingRecovery)
    }

    @MainActor
    func testCachedAdoptionOnlyConfirmsTheSameLiveCoordinator() throws {
        let fixture = try RecoveryOperationFixture()
        XCTAssertEqual(try fixture.append("kept"), .accepted)
        XCTAssertEqual(fixture.operation.closeCapture(), .detached(.init(events: 1, utf16Bytes: 8)))
        fixture.finishRecovery()
        guard case .adopted(let identifier) = fixture.operation.adopt(in: fixture.coordinator, reason: .gateLost) else {
            return XCTFail("Исходный coordinator должен принять запись")
        }
        let foreign = RecoveryCoordinator()
        XCTAssertEqual(fixture.operation.adopt(in: foreign, reason: .gateLost), .rejected(.wrongBinding))
        XCTAssertFalse(foreign.hasPendingRecovery)
        XCTAssertEqual(fixture.operation.adopt(in: fixture.coordinator, reason: .gateLost), .adopted(identifier))
        XCTAssertEqual(try fixture.revealedTexts(), ["kept"])
        XCTAssertNil(fixture.ledger.claimInput(operation: fixture.ledger.operation))
    }
}
