import Foundation
@testable import LSwitchCore
import XCTest

final class ConversionSafetyDebtTests: XCTestCase {
    @MainActor
    func testCompletedModifierDownMissingUpStillRequiresRecoveryWithoutEditorMutation() throws {
        let ledger = ConversionSafetyLedger(generation: 1)
        let down = try XCTUnwrap(ledger.willSubmit(.modifier, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: down))
        XCTAssertFalse(ledger.observe(.unknown, for: down), "Завершённый token законно остаётся завершённым")
        XCTAssertTrue(ledger.recordOutstandingKeyDebt(for: down))
        XCTAssertFalse(ledger.recordOutstandingKeyDebt(for: down))
        XCTAssertTrue(ledger.hasOutstandingKeyDebt)
        XCTAssertFalse(ledger.hasUnresolvedSubmissions)
        XCTAssertFalse(ledger.hasEditorMutation)
        XCTAssertNil(ledger.willSubmit(.text, operation: ledger.operation))
        let ticket = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        XCTAssertTrue(ledger.recordCleanup(.recoveredObserved, observation: ticket))
        let final = try XCTUnwrap(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: .unchangedByOperation, ordinaryRouteValid: true
        ))
        XCTAssertEqual(final.cleanup, .noOwnedMutation)
        XCTAssertEqual(final.input, .recoveryRequired)
        XCTAssertFalse(final.permitsConfirmedResult)
    }

    @MainActor
    func testDebtPersistsThroughRequestWrappersAndLaterObservedCleanup() throws {
        let ledger = ConversionSafetyLedger(generation: 2)
        let original = ConversionRequest(expectedWord: "ghbdtn", useSelection: false, safetyLedger: ledger)
        let wrapped = original.checkingTarget { true }
            .checkingDocumentContext(.documentProse(document: "fixture")) { .documentProse(document: "fixture") }
        let shared = try XCTUnwrap(wrapped.safetyLedger)
        let down = try XCTUnwrap(shared.willSubmit(.text, operation: shared.operation))
        XCTAssertTrue(shared.observe(.receiverCompleted, for: down))
        let old = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        XCTAssertTrue(ledger.recordCleanup(.recoveredObserved, observation: old))
        XCTAssertTrue(shared.recordOutstandingKeyDebt(for: down))
        let fresh = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        XCTAssertTrue(ledger.recordCleanup(.recoveredObserved, observation: fresh))
        let final = try XCTUnwrap(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: .confirmed, ordinaryRouteValid: true
        ))
        XCTAssertEqual(final.input, .recoveryRequired)
        XCTAssertEqual(final.cleanup, .recoveredObserved)
        XCTAssertFalse(final.permitsConfirmedResult)
        XCTAssertEqual(ledger.claimInput(operation: ledger.operation)?.owner, .recovery)
    }

    @MainActor
    func testForeignPreventedReleaseAndClosedTokensCannotCreateDebt() throws {
        let ledger = ConversionSafetyLedger(generation: 3)
        let foreign = ConversionSafetyLedger(generation: 3)
        let other = try XCTUnwrap(foreign.willSubmit(.modifier, operation: foreign.operation))
        XCTAssertFalse(ledger.recordOutstandingKeyDebt(for: other))
        let prevented = try XCTUnwrap(ledger.willSubmit(.modifier, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.preventedBeforeAdmission, for: prevented))
        XCTAssertFalse(ledger.recordOutstandingKeyDebt(for: prevented))
        let release = try XCTUnwrap(ledger.willSubmitCleanup(.balancingRelease, operation: ledger.operation))
        XCTAssertFalse(ledger.recordOutstandingKeyDebt(for: release))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: release))
        let final = try XCTUnwrap(ledger.finish(
            operation: ledger.operation, text: .unchangedByOperation,
            cleanup: .noOwnedMutation, ordinaryRouteValid: true
        ))
        XCTAssertFalse(ledger.recordOutstandingKeyDebt(for: prevented))
        XCTAssertEqual(ledger.decision, final)
        XCTAssertEqual(ledger.submissionCount, 2, "Неотправленный Up не превращается в submission")
    }
}
