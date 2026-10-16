import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
struct ConversionSafetyProfileFixture {
    let binding: ConversionSafetyProfileBinding
    let ledger: ConversionSafetyLedger

    init() throws {
        let target = try XCTUnwrap(RecoveryProcessIdentity(processID: 123, birthSeconds: 45, birthMicroseconds: 6))
        binding = .init(profile: .textEditAX119MacOS145, target: target,
                        documentIdentity: UUID(), elementIdentity: UUID(), windowIdentity: UUID())
        ledger = ConversionSafetyLedger(generation: 1, profile: binding)
    }

    func submit(_ kind: ConversionSafetySubmissionKind) throws -> ConversionSafetySubmissionToken {
        let token = try XCTUnwrap(kind.isCleanup
            ? ledger.willSubmitCleanup(kind, operation: ledger.operation)
            : ledger.willSubmit(kind, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.adapterReturned(true), for: token))
        return token
    }

    func accept(_ step: ConversionSafetyProfileStep, token: ConversionSafetySubmissionToken) throws {
        let observation = try XCTUnwrap(ledger.beginProfileObservation(step: step, submission: token, binding: binding))
        XCTAssertTrue(ledger.observeUnderProfile(observation, binding: binding))
    }

    func finalState() throws {
        let observation = try XCTUnwrap(ledger.beginProfileObservation(step: .finalState, binding: binding))
        XCTAssertTrue(ledger.observeUnderProfile(observation, binding: binding))
        let cleanup = try XCTUnwrap(ledger.beginCleanupObservation(operation: ledger.operation))
        XCTAssertTrue(ledger.recordCleanup(.recoveredObserved, observation: cleanup))
    }

    func finish(
        text: ConversionSafetyTextEvidence = .confirmed, route: Bool = true
    ) throws -> ConversionSafetyDecision {
        try XCTUnwrap(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: text, ordinaryRouteValid: route
        ))
    }
}
