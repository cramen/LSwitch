import Foundation
@testable import LSwitchCore
import XCTest

final class ConversionSafetyProfileBindingTests: XCTestCase {
    @MainActor
    func testForeignProcessInstanceDocumentElementAndWindowCannotAcceptOrConsumeTicket() throws {
        let fixture = try ConversionSafetyProfileFixture()
        let binding = fixture.binding
        let token = try fixture.submit(.text)
        let ticket = try XCTUnwrap(fixture.ledger.beginProfileObservation(
            step: .text, submission: token, binding: binding
        ))
        let reusedPID = try XCTUnwrap(RecoveryProcessIdentity(
            processID: binding.target.processID, birthSeconds: 999, birthMicroseconds: 6
        ))
        let targets = [reusedPID, binding.target, binding.target, binding.target]
        for index in 0..<4 {
            let wrong = ConversionSafetyProfileBinding(
                profile: binding.profile, target: targets[index],
                documentIdentity: index == 1 ? UUID() : binding.documentIdentity,
                elementIdentity: index == 2 ? UUID() : binding.elementIdentity,
                windowIdentity: index == 3 ? UUID() : binding.windowIdentity
            )
            XCTAssertNil(fixture.ledger.beginProfileObservation(step: .text, submission: token, binding: wrong))
            XCTAssertFalse(fixture.ledger.observeUnderProfile(ticket, binding: wrong))
        }
        XCTAssertTrue(fixture.ledger.observeUnderProfile(ticket, binding: binding))
        XCTAssertFalse(fixture.ledger.observeUnderProfile(ticket, binding: binding))
    }

    @MainActor
    func testSameGenerationAndTargetCannotShareOperationTicketsOrFaults() throws {
        let fixture = try ConversionSafetyProfileFixture()
        let other = ConversionSafetyLedger(generation: 1, profile: fixture.binding)
        let token = try fixture.submit(.text)
        let foreign = try XCTUnwrap(other.willSubmit(.text, operation: other.operation))
        XCTAssertTrue(other.observe(.adapterReturned(true), for: foreign))
        let ticket = try XCTUnwrap(fixture.ledger.beginProfileObservation(
            step: .text, submission: token, binding: fixture.binding
        ))
        XCTAssertNil(other.beginProfileObservation(step: .text, submission: token, binding: fixture.binding))
        XCTAssertFalse(other.observeUnderProfile(ticket, binding: fixture.binding))
        XCTAssertFalse(other.recordProfileFault(.contextChanged, operation: fixture.ledger.operation))
        XCTAssertFalse(other.hasProfileFault)
        XCTAssertTrue(fixture.ledger.observeUnderProfile(ticket, binding: fixture.binding))
    }

    @MainActor
    func testNewObservationSupersedesEarlierReadAndClosedOperationRejectsAllLateTickets() throws {
        let fixture = try ConversionSafetyProfileFixture()
        let ledger = fixture.ledger
        let token = try fixture.submit(.text)
        let old = try XCTUnwrap(ledger.beginProfileObservation(
            step: .text, submission: token, binding: fixture.binding
        ))
        let fresh = try XCTUnwrap(ledger.beginProfileObservation(
            step: .text, submission: token, binding: fixture.binding
        ))
        XCTAssertFalse(ledger.observeUnderProfile(old, binding: fixture.binding))
        XCTAssertTrue(ledger.observeUnderProfile(fresh, binding: fixture.binding))
        try fixture.finalState()
        let result = try fixture.finish()
        XCTAssertTrue(result.permitsConfirmedResult)
        XCTAssertFalse(ledger.observeUnderProfile(fresh, binding: fixture.binding))
        XCTAssertNil(ledger.beginProfileObservation(step: .finalState, binding: fixture.binding))
        XCTAssertFalse(ledger.recordProfileFault(.contextChanged, operation: ledger.operation))
        XCTAssertEqual(ledger.decision, result)
    }

    @MainActor
    func testReceiverCompletionInvalidatesEarlierProfileReadAndNewSubmissionCannotReuseIt() throws {
        let fixture = try ConversionSafetyProfileFixture()
        let ledger = fixture.ledger
        let token = try fixture.submit(.selection)
        let stale = try XCTUnwrap(ledger.beginProfileObservation(
            step: .selection, submission: token, binding: fixture.binding
        ))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: token))
        _ = try fixture.submit(.text)
        XCTAssertFalse(ledger.observeUnderProfile(stale, binding: fixture.binding))
        XCTAssertTrue(ledger.hasUnacceptedSubmissions)
        XCTAssertEqual(try fixture.finish().input, .recoveryRequired)
    }

    @MainActor
    func testPreventionDuringProfileReadCannotBecomeObservedTextThroughALateTicket() throws {
        let fixture = try ConversionSafetyProfileFixture()
        let token = try fixture.submit(.text)
        let ticket = try XCTUnwrap(fixture.ledger.beginProfileObservation(
            step: .text, submission: token, binding: fixture.binding
        ))
        XCTAssertTrue(fixture.ledger.observe(.preventedBeforeAdmission, for: token))
        XCTAssertFalse(fixture.ledger.observeUnderProfile(ticket, binding: fixture.binding))
        XCTAssertNil(fixture.ledger.beginProfileObservation(step: .finalState, binding: fixture.binding))
        XCTAssertFalse(try fixture.finish().permitsConfirmedResult)
    }

    @MainActor
    func testNewSetterInvalidatesFinalStateAndOldCleanupUntilBothAreObservedAgain() throws {
        let fixture = try ConversionSafetyProfileFixture()
        let ledger = fixture.ledger
        try fixture.accept(.text, token: fixture.submit(.text))
        try fixture.finalState()
        let staleCleanup = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        let restore = try fixture.submit(.restoreSelection)
        XCTAssertFalse(ledger.hasObservedProfileFinalState)
        try fixture.accept(.restoreSelection, token: restore)
        XCTAssertFalse(ledger.recordCleanup(.recoveredObserved, observation: staleCleanup))
        try fixture.finalState()
        XCTAssertTrue(try fixture.finish().permitsConfirmedResult)
    }

    @MainActor
    func testFinalStateCannotBeManufacturedWithoutAcceptedTextOrForAnUnknownToken() throws {
        let fixture = try ConversionSafetyProfileFixture()
        let ledger = fixture.ledger
        XCTAssertNil(ledger.beginProfileObservation(step: .finalState, binding: fixture.binding))
        let missing = ConversionSafetySubmissionToken(operation: ledger.operation, ordinal: 999)
        XCTAssertNil(ledger.beginProfileObservation(step: .text, submission: missing, binding: fixture.binding))
        let selection = try fixture.submit(.selection)
        try fixture.accept(.selection, token: selection)
        XCTAssertNil(ledger.beginProfileObservation(step: .finalState, binding: fixture.binding))
        XCTAssertEqual(try fixture.finish(text: .unchangedByOperation).input, .recoveryRequired)
    }
}
