#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class AXProfileTransactionBoundaryTests: XCTestCase {
    @MainActor
    func testOneGuardSeparatesCountAndPayloadWithoutLosingAnyExternalReadBoundary() throws {
        var calls: [String] = []
        let reader = AXProfileSnapshotReader(readCount: { calls.append("count"); return 1 },
                                             readText: { _ in calls.append("text"); return "a" },
                                             readSelection: {
            calls.append("selection")
            return NSRange(location: 1, length: 0)
        })
        XCTAssertNotNil(reader.read(canRead: { calls.append("guard"); return true }))
        XCTAssertEqual(calls, ["guard", "count", "guard", "text", "guard", "count",
                               "guard", "selection", "guard"])
    }

    @MainActor
    func testCanonicalSubmissionUsesOneFullGuardAfterPreparationAndRejectsForeignElement() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let mutation = AXMutationSafety(request: try fixture.manualRequest(), receiverContract: nil,
                                        profile: fixture.profile)
        let element = fixture.editor.access.model.element
        XCTAssertTrue(mutation.bind(to: element))
        let before = fixture.profile.diagnosticReport.context.count
        XCTAssertFalse(mutation.writeCanonicalSelection(.init(location: 0, length: 6),
            in: fixture.editor.access.model.otherElement, access: fixture.editor.access))
        XCTAssertFalse(mutation.writeCanonicalText("привет", in: fixture.editor.access.model.otherElement,
                                                   access: fixture.editor.access))
        XCTAssertEqual(fixture.editor.access.preparations, 0)
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
        XCTAssertTrue(mutation.writeCanonicalSelection(.init(location: 0, length: 6),
                                                        in: element, access: fixture.editor.access))
        XCTAssertEqual(fixture.profile.diagnosticReport.context.count - before, 2)
        XCTAssertEqual(fixture.ledger.submissionCount, 1)
        XCTAssertEqual(fixture.editor.access.model.selectionWrites.count, 1)
    }

    @MainActor
    func testPreparationReentryIsClosedBeforeCanonicalSubmission() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let mutation = AXMutationSafety(request: try fixture.manualRequest(), receiverContract: nil,
                                        profile: fixture.profile)
        let element = fixture.editor.access.model.element
        XCTAssertTrue(mutation.bind(to: element))
        let access = AXCanonicalManualAccess(fixture.editor.access)
        let converter = fixture.converter
        access.beforePreparation = { converter.notifyOtherKeystroke() }
        XCTAssertFalse(mutation.writeCanonicalSelection(.init(location: 0, length: 6), in: element, access: access))
        XCTAssertEqual(fixture.editor.access.preparations, 1)
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
        XCTAssertTrue(fixture.editor.access.model.selectionWrites.isEmpty)
        XCTAssertTrue(fixture.ledger.hasProfileFault)
    }

    @MainActor
    func testGenericWriteStillHonorsItsArbitraryValidatorEvenWithBoundCanonicalProfile() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let mutation = AXMutationSafety(request: try fixture.manualRequest(), receiverContract: nil,
                                        profile: fixture.profile)
        let element = fixture.editor.access.model.element
        XCTAssertTrue(mutation.bind(to: element))
        XCTAssertFalse(mutation.writeSelection(.init(location: 0, length: 6), in: element,
            access: fixture.editor.access, isValid: { false }))
        XCTAssertFalse(mutation.writeText("привет", in: element, access: fixture.editor.access, isValid: { false }))
        XCTAssertEqual(fixture.editor.access.preparations, 0)
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
    }

    @MainActor
    func testObservationCannotReturnSnapshotAfterItsTicketIsSupersededDuringTheFreshRead() throws {
        let fixture = try AXProfileFixture()
        let operation = try fixture.prepare()
        let ledger = operation.ledger
        let profile = operation.profile
        XCTAssertTrue(profile.bind(to: fixture.access.model.element, ledger: ledger, isValid: { true }))
        let submission = try XCTUnwrap(ledger.willSubmit(.selection, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.adapterReturned(true), for: submission))
        fixture.duringRead = { _ in
            XCTAssertNotNil(ledger.beginProfileObservation(step: .selection, submission: submission,
                                                           binding: profile.binding))
        }
        defer { fixture.duringRead = { _ in } }
        let snapshot = profile.observeSnapshot(
            step: .selection, reply: .init(submission: submission, status: .success),
            expected: .init(fixture.access.model.value, fixture.access.model.currentSelection), ledger: ledger
        )
        XCTAssertNil(snapshot)
        XCTAssertTrue(ledger.hasProfileFault)
        XCTAssertTrue(ledger.hasUnacceptedSubmissions)
        XCTAssertTrue(fixture.access.model.selectionWrites.isEmpty)
    }

    @MainActor
    func testReplacementObservationSelectionIsReusedOnlyUntilFreshFinalSetterGuard() async throws {
        for changesContext in [false, true] {
            let fixture = try AXCombinedProfileFixture()
            await fixture.arm()
            let editor = fixture.editor
            let model = editor.access.model
            var replacementReads = 0
            var observedAtPreparation: [Int] = []
            editor.duringRead = { [weak model] _ in
                if model?.textWrites == 1, model?.selectionWrites.count == 1 { replacementReads += 1 }
            }
            let access = AXCanonicalManualAccess(editor.access)
            access.beforePreparation = { [weak editor, weak model] in
                if model?.textWrites == 1, model?.selectionWrites.count == 1 {
                    observedAtPreparation.append(replacementReads)
                    if changesContext { editor?.document = "fixture:changed-before-final-caret" }
                }
            }
            let engine = AXTextConverter(access: access, observationProfile: fixture.profile)
            let result = await engine.perform(try fixture.manualRequest())
            XCTAssertEqual(observedAtPreparation, [1], "Между observation и final prepare нет повторного snapshot")
            XCTAssertEqual(replacementReads, 1)
            XCTAssertEqual(model.textWrites, 1)
            if changesContext {
                if case .success = result { XCTFail("Смена контекста после snapshot запрещает final setter") }
                XCTAssertEqual(model.selectionWrites.count, 1)
                XCTAssertTrue(fixture.ledger.hasProfileFault)
            } else {
                guard case .success = result else { return XCTFail("Здоровый control должен работать") }
                XCTAssertEqual(model.selectionWrites.count, 2)
                XCTAssertTrue(fixture.ledger.hasObservedProfileFinalState)
            }
        }
    }
}
#endif
