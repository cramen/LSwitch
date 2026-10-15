@testable import LSwitchCore
import XCTest

final class ConversionSafetyCleanupTests: XCTestCase {
    @MainActor
    func testLateObservationCannotAuthorizeReplayAfterAnotherCompletedMutation() throws {
        let ledger = ConversionSafetyLedger(generation: 1)
        let first = try XCTUnwrap(ledger.willSubmit(.selection, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: first))
        let stale = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        let next = try XCTUnwrap(ledger.willSubmit(.text, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: next))
        XCTAssertFalse(ledger.recordCleanup(.recoveredObserved, observation: stale))
        XCTAssertEqual(ledger.recordedCleanup, .recoveryUnconfirmed)
        // Старый finish-аргумент не обходит opt-in в revision-bound evidence.
        let result = try XCTUnwrap(ledger.finish(
            operation: ledger.operation, text: .confirmed, cleanup: .recoveredObserved, ordinaryRouteValid: true
        ))
        XCTAssertEqual(result.input, .recoveryRequired)
        XCTAssertFalse(result.permitsConfirmedResult)
    }

    @MainActor
    func testFreshObservationAfterCompletionCanAuthorizeReplay() throws {
        let ledger = ConversionSafetyLedger(generation: 2)
        let token = try XCTUnwrap(ledger.willSubmit(.text, operation: ledger.operation))
        let old = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.unknown, for: token))
        XCTAssertFalse(ledger.recordCleanup(.recoveredObserved, observation: old))
        let pending = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: token))
        XCTAssertFalse(ledger.recordCleanup(.recoveredObserved, observation: pending))
        let fresh = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        XCTAssertTrue(ledger.recordCleanup(.recoveredObserved, observation: fresh))
        let result = try XCTUnwrap(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: .unknown, ordinaryRouteValid: true
        ))
        XCTAssertEqual(result.input, .replayAuthorized)
        XCTAssertFalse(result.permitsConfirmedResult)
    }

    @MainActor
    func testNewObservationSupersedesOlderReadAndCanOnlyBeRecordedOnce() throws {
        let ledger = ConversionSafetyLedger(generation: 3)
        let token = try XCTUnwrap(ledger.willSubmit(.selection, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: token))
        let old = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        let current = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        XCTAssertFalse(ledger.recordCleanup(.recoveredObserved, observation: old))
        XCTAssertTrue(ledger.recordCleanup(.recoveryUnconfirmed, observation: current))
        XCTAssertFalse(ledger.recordCleanup(.recoveredObserved, observation: current))
        XCTAssertEqual(ledger.recordedCleanup, .recoveryUnconfirmed)
    }

    @MainActor
    func testForeignAndClosedOperationsCannotChangeRecordedEvidence() throws {
        let ledger = ConversionSafetyLedger(generation: 4)
        let foreign = ConversionSafetyLedger(generation: 4)
        let observation = try XCTUnwrap(foreign.beginCleanupObservation(operation: foreign.operation))
        XCTAssertNil(ledger.beginCleanupObservation(operation: foreign.operation))
        XCTAssertFalse(ledger.recordCleanup(.recoveredObserved, observation: observation))
        let own = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        XCTAssertTrue(ledger.recordCleanup(.noOwnedMutation, observation: own))
        XCTAssertNotNil(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: .unchangedByOperation, ordinaryRouteValid: true
        ))
        XCTAssertNil(ledger.beginCleanupObservation(operation: ledger.operation))
        XCTAssertFalse(ledger.recordCleanup(.recoveryUnconfirmed, observation: own))
        XCTAssertEqual(ledger.recordedCleanup, .noOwnedMutation)
    }
}
