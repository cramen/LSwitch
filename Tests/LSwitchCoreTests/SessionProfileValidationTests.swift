#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class SessionProfileValidationTests: XCTestCase {
    @MainActor
    func testTicketsAreScopedOneUseAndASecondOpeningInvalidatesTheFirst() async throws {
        let fixture = try AXCombinedProfileFixture()
        let other = try AXCombinedProfileFixture()
        await fixture.arm()
        await other.arm()
        let targetChecks = fixture.controls.fullTargetChecks
        let first = try open(fixture)
        let second = try open(fixture)
        XCTAssertFalse(fixture.capability.finish(first))
        XCTAssertFalse(other.capability.finish(second))
        XCTAssertNil(fixture.capability.begin(binding: other.profile.binding, operation: fixture.ledger.operation))
        XCTAssertNil(fixture.capability.begin(binding: fixture.profile.binding, operation: other.ledger.operation))
        fixture.controls.hostSafety = { XCTFail("Closing не вызывает host callback"); return false }
        XCTAssertTrue(fixture.capability.finish(second))
        XCTAssertFalse(fixture.capability.finish(second))
        XCTAssertEqual(fixture.controls.fullTargetChecks, targetChecks)
    }

    @MainActor
    func testOpeningCallbackReentryCannotReturnAnOuterOrNestedUsableTicket() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        var inside = false
        var nested: AXProfileValidationToken?
        fixture.controls.hostSafety = {
            if !inside {
                inside = true
                nested = fixture.capability.begin(binding: fixture.profile.binding, operation: fixture.ledger.operation)
            }
            return true
        }
        XCTAssertNil(fixture.capability.begin(binding: fixture.profile.binding, operation: fixture.ledger.operation))
        XCTAssertFalse(fixture.capability.finish(try XCTUnwrap(nested)))
        XCTAssertTrue(fixture.ledger.hasProfileFault)
        XCTAssertEqual(fixture.editor.snapshotReads, 0)
        fixture.controls.hostSafety = { true }
    }

    @MainActor
    func testOpeningHostCallbackCannotHideRevisionOrExactAttemptInvalidation() async throws {
        for mutation in [ClosingMutation.revision, .replacedAttempt, .interrupted] {
            let fixture = try AXCombinedProfileFixture()
            await fixture.arm()
            fixture.controls.hostSafety = { self.mutate(mutation, fixture: fixture); return true }
            XCTAssertNil(fixture.capability.begin(binding: fixture.profile.binding,
                                                  operation: fixture.ledger.operation))
            XCTAssertTrue(fixture.ledger.hasProfileFault)
            XCTAssertEqual(fixture.editor.snapshotReads, 0)
            fixture.controls.hostSafety = { true }
        }
    }

    @MainActor
    func testClosingRejectsRevisionAttemptLeaseGateAndLedgerChangesWithoutAnotherTargetCallback() async throws {
        for mutation in ClosingMutation.allCases {
            let fixture = try AXCombinedProfileFixture()
            await fixture.arm()
            let token = try open(fixture)
            let before = fixture.controls.fullTargetChecks
            mutate(mutation, fixture: fixture)
            XCTAssertFalse(fixture.capability.finish(token), "Closing должен увидеть \(mutation)")
            XCTAssertTrue(fixture.ledger.hasProfileFault)
            XCTAssertEqual(fixture.controls.fullTargetChecks, before)
            XCTAssertEqual(fixture.editor.access.model.textWrites, 0)
            XCTAssertTrue(fixture.editor.access.model.selectionWrites.isEmpty)
        }
    }

    @MainActor
    func testAdditionalGuardAndUndoRequestsCannotKeepCanonicalProvenance() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        XCTAssertNotNil(fixture.request.profileValidation)
        let checked = fixture.request.checkingTarget { false }
        XCTAssertNil(checked.profileValidation)
        XCTAssertFalse(checked.isValid())
        let automatic = fixture.request.checkingDocumentContext(.documentProse(document: "fixture"),
            read: { .documentProse(document: "fixture") })
        XCTAssertNil(automatic.profileValidation)
        let undo = ConversionRequest(canonical: .init(expectedWord: "привет", trailingText: " ", replacement: "ghbdtn",
            sourceLayout: nil, useSelection: false, diagnostics: try XCTUnwrap(fixture.request.diagnostics)),
            session: fixture.session)
        XCTAssertNil(undo.profileValidation)
        let custom = ConversionRequest(safetyLedger: fixture.ledger, isValid: { true })
        XCTAssertNil(custom.profileValidation)
        XCTAssertTrue(custom.safetyLedger === fixture.request.safetyLedger)
    }

    @MainActor
    func testCapabilityDoesNotKeepSessionAliveOrFallbackAfterItsOwnerDisappears() async throws {
        var fixture: AXCombinedProfileFixture? = try AXCombinedProfileFixture()
        await fixture?.arm()
        let capability = try XCTUnwrap(fixture?.capability)
        let binding = try XCTUnwrap(fixture?.profile.binding)
        let operation = try XCTUnwrap(fixture?.ledger.operation)
        let token = try XCTUnwrap(capability.begin(binding: binding, operation: operation))
        weak var session = fixture?.session
        weak var adapter = fixture?.native.adapter
        fixture = nil
        XCTAssertNil(session)
        XCTAssertNil(adapter)
        XCTAssertNil(capability.begin(binding: binding, operation: operation))
        XCTAssertFalse(capability.finish(token))
    }

    @MainActor
    private func open(_ fixture: AXCombinedProfileFixture) throws -> AXProfileValidationToken {
        try XCTUnwrap(fixture.capability.begin(binding: fixture.profile.binding, operation: fixture.ledger.operation))
    }

    private enum ClosingMutation: CaseIterable {
        case revision, replacedAttempt, interrupted, lease, gate, ledger
    }

    @MainActor
    private func mutate(_ mutation: ClosingMutation, fixture: AXCombinedProfileFixture) {
        switch mutation {
        case .revision: fixture.converter.notifyOtherKeystroke()
        case .replacedAttempt:
            fixture.runtime.attempt = TextEditRecoveryAttempt(invocation: fixture.attempt.invocation)
        case .interrupted: fixture.attempt.interruption = .off
        case .lease:
            let arm = fixture.native.adapter.resources.logical.prepared
            XCTAssertFalse(arm.isCurrent(at: arm.deadline))
        case .gate: fixture.native.driver.state.markLost(.tapDisabled)
        case .ledger: fixture.ledger.recordProfileFault(.snapshotMismatch, operation: fixture.ledger.operation)
        }
    }
}
#endif
