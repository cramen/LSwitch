@testable import LSwitchCore
import XCTest

final class ConversionSafetyOwnershipTests: XCTestCase {
    @MainActor
    func testOnlyOneConsumerClaimsOrdinaryDeliveryOrRecovery() throws {
        for routeValid in [false, true] {
            let ledger = ConversionSafetyLedger(generation: 1)
            XCTAssertNil(ledger.claimInput(operation: ledger.operation))
            XCTAssertEqual(ledger.inputOwner, .transaction)
            XCTAssertNotNil(ledger.finish(
                operation: ledger.operation, text: .unchangedByOperation,
                cleanup: .noOwnedMutation, ordinaryRouteValid: routeValid
            ))
            XCTAssertEqual(ledger.inputOwner, .transaction)
            let firstConsumer = try XCTUnwrap(ledger.claimInput(operation: ledger.operation))
            XCTAssertEqual(firstConsumer.owner, routeValid ? .ordinaryDelivery : .recovery)
            XCTAssertEqual(ledger.inputOwner, firstConsumer.owner)
            XCTAssertNil(ledger.claimInput(operation: ledger.operation))
        }
    }

    @MainActor
    func testOldAndForeignTokensCannotCloseOrClaimCurrentGeneration() throws {
        let old = ConversionSafetyLedger(generation: 12)
        let oldSubmission = try XCTUnwrap(old.willSubmit(.selection, operation: old.operation))
        for generation: UInt64 in [12, 13] {
            let current = ConversionSafetyLedger(generation: generation)
            XCTAssertNil(current.willSubmit(.text, operation: old.operation))
            XCTAssertNil(current.willSubmitCleanup(.restoreSelection, operation: old.operation))
            XCTAssertFalse(current.observe(.receiverCompleted, for: oldSubmission))
            XCTAssertFalse(current.observe(.unknown, for: oldSubmission))
            XCTAssertNil(current.finish(
                operation: old.operation, text: .confirmed, cleanup: .recoveredObserved, ordinaryRouteValid: true
            ))
            XCTAssertNil(current.claimInput(operation: old.operation))
            XCTAssertEqual(current.submissionCount, 0)
            XCTAssertFalse(current.encounteredUnknown)
            XCTAssertEqual(current.inputOwner, .transaction)
            XCTAssertNotNil(current.finish(
                operation: current.operation, text: .unchangedByOperation,
                cleanup: .noOwnedMutation, ordinaryRouteValid: true
            ))
            XCTAssertEqual(current.claimInput(operation: current.operation)?.owner, .ordinaryDelivery)
        }
    }

    @MainActor
    func testStrongProofAfterFinishCannotUpgradeDispositionOrTakeBackRecovery() throws {
        let ledger = ConversionSafetyLedger(generation: 2)
        let token = try XCTUnwrap(ledger.willSubmit(.text, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.unknown, for: token))
        let result = try XCTUnwrap(ledger.finish(
            operation: ledger.operation, text: .unknown, cleanup: .recoveredObserved, ordinaryRouteValid: true
        ))
        XCTAssertEqual(result.input, .recoveryRequired)
        XCTAssertEqual(ledger.claimInput(operation: ledger.operation)?.owner, .recovery)
        XCTAssertFalse(ledger.observe(.receiverCompleted, for: token))
        XCTAssertFalse(ledger.observe(.preventedBeforeAdmission, for: token))
        XCTAssertNil(ledger.finish(
            operation: ledger.operation, text: .confirmed, cleanup: .recoveredObserved, ordinaryRouteValid: true
        ))
        XCTAssertNil(ledger.claimInput(operation: ledger.operation))
        XCTAssertNil(ledger.willSubmit(.text, operation: ledger.operation))
        XCTAssertNil(ledger.willSubmitCleanup(.balancingRelease, operation: ledger.operation))
        XCTAssertEqual(ledger.decision, result)
        XCTAssertEqual(ledger.inputOwner, .recovery)
    }

    @MainActor
    func testTimeoutAndCompletionOrderProducesOneImmutableDecision() throws {
        for proofBeforeFinish in [false, true] {
            let ledger = ConversionSafetyLedger(generation: 3)
            let token = try XCTUnwrap(ledger.willSubmit(.selection, operation: ledger.operation))
            XCTAssertTrue(ledger.observe(.admitted, for: token))
            XCTAssertTrue(ledger.observe(.unknown, for: token))
            if proofBeforeFinish { XCTAssertTrue(ledger.observe(.receiverCompleted, for: token)) }
            let result = try XCTUnwrap(ledger.finish(
                operation: ledger.operation, text: .unchangedByOperation,
                cleanup: .recoveredObserved, ordinaryRouteValid: true
            ))
            XCTAssertEqual(result.input, proofBeforeFinish ? .replayAuthorized : .recoveryRequired)
            var claims = 0
            if ledger.claimInput(operation: ledger.operation) != nil { claims += 1 }
            XCTAssertFalse(ledger.observe(.receiverCompleted, for: token))
            XCTAssertNil(ledger.finish(
                operation: ledger.operation, text: .unchangedByOperation,
                cleanup: .recoveredObserved, ordinaryRouteValid: true
            ))
            if ledger.claimInput(operation: ledger.operation) != nil { claims += 1 }
            XCTAssertEqual(claims, 1)
            XCTAssertEqual(ledger.decision, result)
        }
    }

    @MainActor
    func testDangerousOwnSelectionNeedsRecoveryWithoutAnyBufferedPayload() throws {
        let ledger = ConversionSafetyLedger(generation: 4)
        XCTAssertNotNil(ledger.willSubmit(.selection, operation: ledger.operation))
        let result = try XCTUnwrap(ledger.finish(
            operation: ledger.operation, text: .unchangedByOperation,
            cleanup: .recoveryUnconfirmed, ordinaryRouteValid: true
        ))
        XCTAssertEqual(result.input, .recoveryRequired)
        // В этой модели вообще нет payload: опасное выделение не зависит от числа удержанных событий.
        XCTAssertEqual(ledger.claimInput(operation: ledger.operation)?.owner, .recovery)
    }

    @MainActor
    func testSubmissionOrdinalsRemainMonotonicAcrossNormalAndCleanupCommands() throws {
        let ledger = ConversionSafetyLedger(generation: 5)
        let selection = try XCTUnwrap(ledger.willSubmit(.selection, operation: ledger.operation))
        let copy = try XCTUnwrap(ledger.willSubmit(.copy, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.unknown, for: copy))
        let release = try XCTUnwrap(ledger.willSubmitCleanup(.balancingRelease, operation: ledger.operation))
        XCTAssertEqual([selection.ordinal, copy.ordinal, release.ordinal], [1, 2, 3])
        XCTAssertEqual(selection.operation, ledger.operation)
        XCTAssertEqual(release.operation, ledger.operation)
        XCTAssertEqual(ledger.submissionCount, 3)
        XCTAssertFalse(ledger.permitsOrdinarySubmission)
    }
}
