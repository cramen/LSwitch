import Foundation
@testable import LSwitchCore
import XCTest

final class ConversionSafetyProfileTests: XCTestCase {
    @MainActor
    func testSequentialAXProfileResultNeverClaimsReceiverCompletion() throws {
        let fixture = try ConversionSafetyProfileFixture()
        let ledger = fixture.ledger
        let selection = try fixture.submit(.selection)
        XCTAssertFalse(ledger.permitsOrdinarySubmission)
        XCTAssertNil(ledger.willSubmit(.text, operation: ledger.operation))
        try fixture.accept(.selection, token: selection)
        XCTAssertTrue(ledger.hasUnresolvedSubmissions, "Наблюдение не превращается в receiverCompleted")
        XCTAssertFalse(ledger.hasUnacceptedSubmissions)
        let text = try fixture.submit(.text)
        try fixture.accept(.text, token: text)
        let restore = try fixture.submit(.restoreSelection)
        try fixture.accept(.restoreSelection, token: restore)
        try fixture.finalState()
        let result = try fixture.finish()
        XCTAssertEqual(result.verificationBasis, .observedUnderProfile)
        XCTAssertTrue(result.permitsConfirmedResult)
        XCTAssertEqual(result.input, .replayAuthorized)
        XCTAssertTrue(ledger.hasUnresolvedSubmissions)
        XCTAssertFalse(ledger.hasUnacceptedSubmissions)
        XCTAssertFalse(ledger.hasProfileFault)
    }

    @MainActor
    func testRawSuccessRequiresMatchingStepAndFinalStateDoesNotCreateASubmission() throws {
        let fixture = try ConversionSafetyProfileFixture()
        let ledger = fixture.ledger
        let token = try XCTUnwrap(ledger.willSubmit(.text, operation: ledger.operation))
        XCTAssertNil(ledger.beginProfileObservation(step: .text, submission: token, binding: fixture.binding))
        XCTAssertTrue(ledger.observe(.adapterReturned(true), for: token))
        XCTAssertNil(ledger.beginProfileObservation(step: .selection, submission: token, binding: fixture.binding))
        XCTAssertNil(ledger.beginProfileObservation(step: .finalState, submission: token, binding: fixture.binding))
        XCTAssertNil(ledger.beginProfileObservation(step: .finalState, binding: fixture.binding))
        try fixture.accept(.text, token: token)
        try fixture.finalState()
        XCTAssertEqual(ledger.submissionCount, 1)
        XCTAssertTrue(try fixture.finish().permitsConfirmedResult)
    }

    @MainActor
    func testAcceptedTextAloneCannotReplaceFinalStateOrOrdinaryRoute() throws {
        for hasFinal in [false, true] {
            let fixture = try ConversionSafetyProfileFixture()
            try fixture.accept(.text, token: fixture.submit(.text))
            if hasFinal { try fixture.finalState() }
            let result = try fixture.finish(route: !hasFinal)
            XCTAssertEqual(result.input, .recoveryRequired)
            XCTAssertFalse(result.permitsConfirmedResult)
            XCTAssertEqual(result.verificationBasis, .unconfirmed)
        }
    }

    @MainActor
    func testStrictModeDoesNotAcceptProfileTicketsAndKeepsItsCompletionSemantics() throws {
        let fixture = try ConversionSafetyProfileFixture()
        let strict = ConversionSafetyLedger(generation: 1)
        let token = try XCTUnwrap(strict.willSubmit(.text, operation: strict.operation))
        XCTAssertTrue(strict.observe(.adapterReturned(true), for: token))
        XCTAssertNil(strict.beginProfileObservation(step: .text, submission: token, binding: fixture.binding))
        XCTAssertTrue(strict.observe(.receiverCompleted, for: token))
        let result = try XCTUnwrap(strict.finish(operation: strict.operation, text: .confirmed,
                                               cleanup: .recoveredObserved, ordinaryRouteValid: true))
        XCTAssertTrue(result.permitsConfirmedResult)
        XCTAssertEqual(result.verificationBasis, .receiverCompleted)
    }

    @MainActor
    func testNativeKindsAreNotEnabledByTheAXProfileAndPreventionCannotEraseObservedEffect() throws {
        let fixture = try ConversionSafetyProfileFixture()
        let ledger = fixture.ledger
        XCTAssertNil(ledger.willSubmit(.copy, operation: ledger.operation))
        XCTAssertNil(ledger.willSubmit(.modifier, operation: ledger.operation))
        XCTAssertNil(ledger.willSubmitCleanup(.balancingRelease, operation: ledger.operation))
        let token = try fixture.submit(.text)
        try fixture.accept(.text, token: token)
        XCTAssertFalse(ledger.observe(.preventedBeforeAdmission, for: token))
        XCTAssertTrue(ledger.hasUnresolvedSubmissions)
        XCTAssertFalse(ledger.hasUnacceptedSubmissions)
    }

}
