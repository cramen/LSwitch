@testable import LSwitchCore
import XCTest

final class ConversionSafetyDeliveryRefusalTests: XCTestCase {
    @MainActor
    func testRefusalPreservesHistoricalDecisionButRevokesCurrentReceiptAndOrdinaryClaim() throws {
        let fixture = try ConversionSafetyProfileFixture()
        try fixture.accept(.text, token: fixture.submit(.text))
        try fixture.finalState()
        let historical = try fixture.finish()
        let ledger = fixture.ledger
        XCTAssertTrue(ledger.permitsConfirmedResult)
        XCTAssertEqual(ledger.currentInputDisposition, .replayAuthorized)
        XCTAssertTrue(ledger.recordOrdinaryDeliveryRefusal(operation: ledger.operation))
        XCTAssertTrue(ledger.recordOrdinaryDeliveryRefusal(operation: ledger.operation), "Повтор до claim идемпотентен")
        XCTAssertEqual(ledger.decision, historical)
        XCTAssertEqual(historical.verificationBasis, .observedUnderProfile)
        XCTAssertTrue(historical.permitsConfirmedResult, "История не переписывается")
        XCTAssertEqual(ledger.currentInputDisposition, .recoveryRequired)
        XCTAssertFalse(ledger.permitsConfirmedResult)
        XCTAssertEqual(ledger.inputOwner, .transaction)
        XCTAssertEqual(ledger.claimInput(operation: ledger.operation)?.owner, .recovery)
        XCTAssertNil(ledger.claimInput(operation: ledger.operation))
        XCTAssertFalse(ledger.recordOrdinaryDeliveryRefusal(operation: ledger.operation))
    }

    @MainActor
    func testPrefinishForeignAndAlreadyRecoveryDecisionsRejectRefusalWithoutSideEffects() throws {
        let ledger = ConversionSafetyLedger(generation: 1)
        let foreign = ConversionSafetyLedger(generation: 1)
        XCTAssertFalse(ledger.recordOrdinaryDeliveryRefusal(operation: ledger.operation))
        XCTAssertNil(ledger.currentInputDisposition)
        XCTAssertFalse(ledger.permitsConfirmedResult)
        let historical = try XCTUnwrap(ledger.finish(
            operation: ledger.operation, text: .unchangedByOperation,
            cleanup: .noOwnedMutation, ordinaryRouteValid: true
        ))
        XCTAssertFalse(ledger.recordOrdinaryDeliveryRefusal(operation: foreign.operation))
        XCTAssertEqual(ledger.currentInputDisposition, .replayAuthorized)
        XCTAssertEqual(ledger.decision, historical)
        _ = foreign.finish(operation: foreign.operation, text: .unknown,
                           cleanup: .recoveryUnconfirmed, ordinaryRouteValid: false)
        XCTAssertFalse(foreign.recordOrdinaryDeliveryRefusal(operation: foreign.operation))
        XCTAssertEqual(foreign.claimInput(operation: foreign.operation)?.owner, .recovery)
    }

    @MainActor
    func testAcceptedOrdinaryClaimCannotBeRevokedOrReissuedAsRecovery() throws {
        let ledger = ConversionSafetyLedger(generation: 2)
        let text = try XCTUnwrap(ledger.willSubmit(.text, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: text))
        let historical = try XCTUnwrap(ledger.finish(operation: ledger.operation, text: .confirmed,
                                                   cleanup: .recoveredObserved, ordinaryRouteValid: true))
        XCTAssertEqual(ledger.claimInput(operation: ledger.operation)?.owner, .ordinaryDelivery)
        XCTAssertFalse(ledger.recordOrdinaryDeliveryRefusal(operation: ledger.operation))
        XCTAssertEqual(ledger.inputOwner, .ordinaryDelivery)
        XCTAssertEqual(ledger.currentInputDisposition, .replayAuthorized)
        XCTAssertTrue(ledger.permitsConfirmedResult)
        XCTAssertNil(ledger.claimInput(operation: ledger.operation))
        XCTAssertEqual(ledger.decision, historical)
    }

    @MainActor
    func testRealCoordinatorAdoptsRetainedBatchAfterPreclaimTransportRefusal() throws {
        let fixture = try RecoveryOperationFixture()
        XCTAssertEqual(try fixture.append("kept"), .accepted)
        let ledger = fixture.ledger
        let text = try XCTUnwrap(ledger.willSubmit(.text, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: text))
        let historical = try XCTUnwrap(ledger.finish(operation: ledger.operation, text: .confirmed,
                                                   cleanup: .recoveredObserved, ordinaryRouteValid: true))
        XCTAssertEqual(fixture.operation.closeCapture(), .detached(.init(events: 1, utf16Bytes: 8)))
        XCTAssertEqual(fixture.operation.adopt(in: fixture.coordinator, reason: .cleanupUnconfirmed),
                       .ordinaryDeliveryUnavailable)
        XCTAssertEqual(ledger.inputOwner, .transaction)
        XCTAssertTrue(ledger.recordOrdinaryDeliveryRefusal(operation: ledger.operation))
        guard case .adopted(let identifier) = fixture.operation.adopt(
            in: fixture.coordinator, reason: .cleanupUnconfirmed
        ) else { return XCTFail("Отказ transport до claim должен сохранять возможность настоящего RAM adopt") }
        XCTAssertEqual(try fixture.revealedTexts(), ["kept"])
        XCTAssertEqual(ledger.inputOwner, .recovery)
        XCTAssertFalse(ledger.permitsConfirmedResult)
        XCTAssertEqual(ledger.decision, historical)
        XCTAssertEqual(fixture.operation.adopt(in: fixture.coordinator, reason: .cleanupUnconfirmed),
                       .adopted(identifier))
        XCTAssertNil(ledger.claimInput(operation: ledger.operation))
    }

    @MainActor
    func testEmptyQueueStillHasExactlyOneRecoveryOwnerAfterRefusal() throws {
        let fixture = try RecoveryOperationFixture()
        let ledger = fixture.ledger
        _ = ledger.finish(operation: ledger.operation, text: .unchangedByOperation,
                          cleanup: .noOwnedMutation, ordinaryRouteValid: true)
        XCTAssertTrue(ledger.recordOrdinaryDeliveryRefusal(operation: ledger.operation))
        XCTAssertEqual(fixture.operation.closeCapture(), .detached(.init(events: 0, utf16Bytes: 0)))
        guard case .adopted = fixture.operation.adopt(in: fixture.coordinator, reason: .cleanupUnconfirmed) else {
            return XCTFail("Нулевой payload не отменяет владение recovery")
        }
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 0)
        XCTAssertEqual(ledger.inputOwner, .recovery)
        XCTAssertNil(ledger.claimInput(operation: ledger.operation))
    }
}
