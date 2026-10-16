@testable import LSwitchCore
import XCTest

final class ConversionSafetyProfileFaultTests: XCTestCase {
    @MainActor
    func testEveryProfileFaultIsStickyAcrossLateCompletionAndMatchingReadback() throws {
        let reasons: [ConversionSafetyProfileFault] = [
            .contextChanged, .cancelled, .writeRejected, .snapshotUnavailable, .snapshotMismatch,
            .preparationFailed, .unknownSubmission, .outstandingKeyDebt, .cleanupUnconfirmed, .unconfirmedResult
        ]
        for reason in reasons {
            let fixture = try ConversionSafetyProfileFixture()
            let ledger = fixture.ledger
            let token = try fixture.submit(.text)
            let ticket = try XCTUnwrap(ledger.beginProfileObservation(
                step: .text, submission: token, binding: fixture.binding
            ))
            XCTAssertTrue(ledger.recordProfileFault(reason, operation: ledger.operation))
            XCTAssertFalse(ledger.recordProfileFault(.contextChanged, operation: ledger.operation))
            XCTAssertEqual(ledger.profileFault, reason)
            XCTAssertFalse(ledger.observeUnderProfile(ticket, binding: fixture.binding))
            XCTAssertTrue(ledger.observe(.receiverCompleted, for: token), "Сильный поздний факт можно сохранить")
            let fresh = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
            XCTAssertTrue(ledger.recordCleanup(.recoveredObserved, observation: fresh))
            XCTAssertNil(ledger.willSubmit(.text, operation: ledger.operation))
            XCTAssertNil(ledger.willSubmitCleanup(.restoreSelection, operation: ledger.operation))
            XCTAssertNil(ledger.beginProfileObservation(step: .finalState, binding: fixture.binding))
            let result = try fixture.finish()
            XCTAssertEqual(result.input, .recoveryRequired)
            XCTAssertFalse(result.permitsConfirmedResult)
            XCTAssertEqual(result.verificationBasis, .unconfirmed)
        }
    }

    @MainActor
    func testRejectedRPCAndUnknownObservationCreateFaultWithoutAnAdapterFollowup() throws {
        for observation: ConversionSafetySubmissionObservation in [.adapterReturned(false), .unknown] {
            let fixture = try ConversionSafetyProfileFixture()
            let ledger = fixture.ledger
            let token = try XCTUnwrap(ledger.willSubmit(.selection, operation: ledger.operation))
            XCTAssertTrue(ledger.observe(observation, for: token))
            XCTAssertTrue(ledger.hasProfileFault)
            XCTAssertNil(ledger.willSubmitCleanup(.restoreSelection, operation: ledger.operation))
            XCTAssertEqual(try fixture.finish().input, .recoveryRequired)
        }
    }

    @MainActor
    func testOutstandingDebtAndUnknownFinalTextCannotReuseAnEarlierObservedSuccess() throws {
        for addDebt in [false, true] {
            let fixture = try ConversionSafetyProfileFixture()
            let token = try fixture.submit(.text)
            try fixture.accept(.text, token: token)
            try fixture.finalState()
            if addDebt { XCTAssertTrue(fixture.ledger.recordOutstandingKeyDebt(for: token)) }
            let result = try fixture.finish(text: addDebt ? .confirmed : .unknown)
            XCTAssertTrue(fixture.ledger.hasProfileFault)
            XCTAssertEqual(result.input, .recoveryRequired)
            XCTAssertFalse(result.permitsConfirmedResult)
        }
    }

    @MainActor
    func testUnconfirmedCleanupInvalidatesEarlierFinalStateAndCannotBePromotedLater() throws {
        let fixture = try ConversionSafetyProfileFixture()
        try fixture.accept(.text, token: fixture.submit(.text))
        try fixture.finalState()
        let ledger = fixture.ledger
        let failed = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        XCTAssertTrue(ledger.recordCleanup(.recoveryUnconfirmed, observation: failed))
        XCTAssertTrue(ledger.hasProfileFault)
        XCTAssertFalse(ledger.hasObservedProfileFinalState)
        let late = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        XCTAssertTrue(ledger.recordCleanup(.recoveredObserved, observation: late))
        XCTAssertEqual(try fixture.finish().input, .recoveryRequired)
    }

    @MainActor
    func testFaultBeforeAnySubmissionPreservesNoMutationButRequiresRecovery() throws {
        let fixture = try ConversionSafetyProfileFixture()
        XCTAssertTrue(fixture.ledger.recordProfileFault(.contextChanged, operation: fixture.ledger.operation))
        let result = try fixture.finish(text: .unchangedByOperation)
        XCTAssertEqual(result.cleanup, .noOwnedMutation)
        XCTAssertEqual(result.input, .recoveryRequired)
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
    }

    @MainActor
    func testStrictModeIsNotChangedByAProfileFaultCall() throws {
        let strict = ConversionSafetyLedger(generation: 1)
        XCTAssertFalse(strict.recordProfileFault(.writeRejected, operation: strict.operation))
        let token = try XCTUnwrap(strict.willSubmit(.text, operation: strict.operation))
        XCTAssertTrue(strict.observe(.unknown, for: token))
        XCTAssertTrue(strict.observe(.receiverCompleted, for: token))
        let result = try XCTUnwrap(strict.finish(operation: strict.operation, text: .unknown,
                                               cleanup: .recoveredObserved, ordinaryRouteValid: true))
        XCTAssertEqual(result.input, .replayAuthorized, "Принятый strict completion контракт не изменяется")
        XCTAssertFalse(result.permitsConfirmedResult)
    }
}
