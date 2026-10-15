@testable import LSwitchCore
import XCTest

final class ConversionSafetyLedgerTests: XCTestCase {
    @MainActor
    func testNoOwnSubmissionNeedsValidRouteButNoInventedAXCleanup() throws {
        for routeValid in [false, true] {
            let ledger = ConversionSafetyLedger(generation: 1)
            let result = try XCTUnwrap(ledger.finish(
                operation: ledger.operation, text: .unchangedByOperation,
                cleanup: .recoveryUnconfirmed, ordinaryRouteValid: routeValid
            ))
            XCTAssertEqual(result.cleanup, .noOwnedMutation)
            XCTAssertEqual(result.input, routeValid ? .replayAuthorized : .recoveryRequired)
            XCTAssertFalse(result.permitsConfirmedResult)
            XCTAssertEqual(ledger.submissionCount, 0)
        }
    }

    @MainActor
    func testAttemptIsRecordedBeforeFailingSetterAndCannotBecomeNoOwnedMutation() throws {
        let ledger = ConversionSafetyLedger(generation: 2)
        let token = try XCTUnwrap(ledger.willSubmit(.selection, operation: ledger.operation))
        let setter = {
            XCTAssertTrue(ledger.hasEditorMutation)
            XCTAssertTrue(ledger.hasUnresolvedSubmissions)
            return false
        }
        XCTAssertTrue(ledger.observe(.adapterReturned(setter()), for: token))
        let result = try finish(ledger, cleanup: .noOwnedMutation)
        XCTAssertEqual(result.cleanup, .recoveryUnconfirmed)
        XCTAssertEqual(result.input, .recoveryRequired)
    }

    @MainActor
    func testAPIResponseAndAdmissionNeverProveReceiverCompletion() throws {
        for returned in [false, true] {
            let ledger = ConversionSafetyLedger(generation: 3)
            let token = try XCTUnwrap(ledger.willSubmit(.text, operation: ledger.operation))
            XCTAssertTrue(ledger.observe(.adapterReturned(returned), for: token))
            XCTAssertTrue(ledger.observe(.admitted, for: token))
            let result = try finish(ledger, text: .confirmed)
            XCTAssertEqual(result.cleanup, .recoveredObserved)
            XCTAssertEqual(result.input, .recoveryRequired)
            XCTAssertFalse(result.permitsConfirmedResult)
        }
    }

    @MainActor
    func testCompletedTextAndObservedRecoveryPermitNormalConfirmedResult() throws {
        let ledger = ConversionSafetyLedger(generation: 4)
        let token = try XCTUnwrap(ledger.willSubmit(.text, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: token))
        let result = try finish(ledger, text: .confirmed)
        XCTAssertEqual(result.input, .replayAuthorized)
        XCTAssertEqual(result.cleanup, .recoveredObserved)
        XCTAssertTrue(result.permitsConfirmedResult)
    }

    @MainActor
    func testReceiverCompletionDoesNotReplaceCleanupOrOrdinaryRouteProof() throws {
        for routeValid in [false, true] {
            let ledger = ConversionSafetyLedger(generation: 5)
            let token = try XCTUnwrap(ledger.willSubmit(.selection, operation: ledger.operation))
            XCTAssertTrue(ledger.observe(.receiverCompleted, for: token))
            let result = try XCTUnwrap(ledger.finish(
                operation: ledger.operation, text: .unchangedByOperation,
                cleanup: routeValid ? .recoveryUnconfirmed : .recoveredObserved, ordinaryRouteValid: routeValid
            ))
            XCTAssertEqual(result.input, .recoveryRequired)
        }
    }

    @MainActor
    func testCopyAndBalancingReleaseAreExternalSubmissionsButNotEditorMutation() throws {
        for kind: ConversionSafetySubmissionKind in [.copy, .balancingRelease] {
            let ledger = ConversionSafetyLedger(generation: 6)
            let token = try XCTUnwrap(kind == .copy
                ? ledger.willSubmit(kind, operation: ledger.operation)
                : ledger.willSubmitCleanup(kind, operation: ledger.operation))
            XCTAssertFalse(ledger.hasEditorMutation)
            XCTAssertTrue(ledger.hasUnresolvedSubmissions)
            XCTAssertTrue(ledger.observe(.receiverCompleted, for: token))
            let result = try finish(ledger, cleanup: .recoveryUnconfirmed)
            XCTAssertEqual(result.cleanup, .noOwnedMutation)
            XCTAssertEqual(result.input, .replayAuthorized)
        }
    }

    @MainActor
    func testUnresolvedCopyStillRequiresRecoveryWithoutEditorMutation() throws {
        let ledger = ConversionSafetyLedger(generation: 7)
        let token = try XCTUnwrap(ledger.willSubmit(.copy, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.adapterReturned(true), for: token))
        XCTAssertTrue(ledger.observe(.unknown, for: token))
        let result = try finish(ledger)
        XCTAssertEqual(result.cleanup, .noOwnedMutation)
        XCTAssertEqual(result.input, .recoveryRequired)
    }

    @MainActor
    func testStrongProofBeforeFinishCanResolveUnknownWithoutRestoringSubmissionOrSuccess() throws {
        for proof: ConversionSafetySubmissionObservation in [.receiverCompleted, .preventedBeforeAdmission] {
            let ledger = ConversionSafetyLedger(generation: 8)
            let token = try XCTUnwrap(ledger.willSubmit(.text, operation: ledger.operation))
            XCTAssertTrue(ledger.observe(.unknown, for: token))
            XCTAssertTrue(ledger.hasUnknownSubmissions)
            XCTAssertFalse(ledger.permitsOrdinarySubmission)
            XCTAssertTrue(ledger.observe(proof, for: token))
            XCTAssertFalse(ledger.hasUnknownSubmissions)
            XCTAssertFalse(ledger.hasUnresolvedSubmissions)
            XCTAssertTrue(ledger.encounteredUnknown)
            XCTAssertNil(ledger.willSubmit(.text, operation: ledger.operation))
            let result = try finish(ledger, text: .confirmed)
            XCTAssertEqual(result.input, .replayAuthorized)
            XCTAssertFalse(result.permitsConfirmedResult)
        }
    }

    @MainActor
    func testUnknownTextCanHaveIndependentSafeDeliveryButNeverConfirmedResult() throws {
        let ledger = ConversionSafetyLedger(generation: 9)
        let token = try XCTUnwrap(ledger.willSubmit(.text, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: token))
        let result = try finish(ledger, text: .unknown)
        XCTAssertEqual(result.text, .unknown)
        XCTAssertEqual(result.input, .replayAuthorized)
        XCTAssertFalse(result.permitsConfirmedResult)
    }

    @MainActor
    func testCleanupAfterUnknownCannotResolveEarlierUncertainCommandByItself() throws {
        let ledger = ConversionSafetyLedger(generation: 10)
        let selection = try XCTUnwrap(ledger.willSubmit(.selection, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.unknown, for: selection))
        XCTAssertNil(ledger.willSubmit(.selection, operation: ledger.operation))
        XCTAssertNil(ledger.willSubmit(.copy, operation: ledger.operation))
        XCTAssertNil(ledger.willSubmitCleanup(.text, operation: ledger.operation))
        let restore = try XCTUnwrap(ledger.willSubmitCleanup(.restoreSelection, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: restore))
        XCTAssertTrue(ledger.hasEditorMutation)
        XCTAssertTrue(ledger.hasUnknownSubmissions)
        XCTAssertEqual(try finish(ledger).input, .recoveryRequired)
    }

    @MainActor
    func testPreventionCannotRetroactivelyCancelAdmittedCommand() throws {
        let ledger = ConversionSafetyLedger(generation: 11)
        let token = try XCTUnwrap(ledger.willSubmit(.text, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.admitted, for: token))
        XCTAssertFalse(ledger.observe(.preventedBeforeAdmission, for: token))
        XCTAssertTrue(ledger.hasUnresolvedSubmissions)
        XCTAssertEqual(try finish(ledger).input, .recoveryRequired)
    }

    @MainActor
    func testPreventedTextDoesNotPermitPublishingAConversion() throws {
        let ledger = ConversionSafetyLedger(generation: 12)
        let token = try XCTUnwrap(ledger.willSubmit(.text, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.preventedBeforeAdmission, for: token))
        XCTAssertFalse(ledger.observe(.admitted, for: token))
        XCTAssertFalse(ledger.observe(.receiverCompleted, for: token))
        let result = try finish(ledger, text: .confirmed)
        XCTAssertEqual(result.input, .replayAuthorized)
        XCTAssertFalse(result.permitsConfirmedResult)
    }

    @MainActor
    func testDuplicateResponsesDoNotEraseEarlierEvidence() throws {
        let ledger = ConversionSafetyLedger(generation: 13)
        let token = try XCTUnwrap(ledger.willSubmit(.text, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: token))
        XCTAssertTrue(ledger.observe(.adapterReturned(false), for: token))
        XCTAssertFalse(ledger.observe(.adapterReturned(true), for: token))
        XCTAssertFalse(ledger.observe(.receiverCompleted, for: token))
        XCTAssertFalse(ledger.observe(.unknown, for: token))
        XCTAssertFalse(ledger.encounteredUnknown)
        XCTAssertTrue(try finish(ledger, text: .confirmed).permitsConfirmedResult)
    }

    @MainActor
    private func finish(
        _ ledger: ConversionSafetyLedger, text: ConversionSafetyTextEvidence = .unchangedByOperation,
        cleanup: ConversionSafetyCleanupEvidence = .recoveredObserved
    ) throws -> ConversionSafetyDecision {
        try XCTUnwrap(ledger.finish(
            operation: ledger.operation, text: text, cleanup: cleanup, ordinaryRouteValid: true
        ))
    }
}
