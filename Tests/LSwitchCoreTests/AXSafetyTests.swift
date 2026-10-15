import ApplicationServices
import Foundation
@testable import LSwitchCore
import XCTest

final class AXSafetyTests: XCTestCase {
    @MainActor
    func testTrackedPathWithoutBoundContractRefusesBeforePreparationOrSetter() async {
        let access = AXSafetyTestAccess("ghbdtn ")
        let ledger = ConversionSafetyLedger(generation: 1)
        let execution = await AXTextConverter(access: access).performWithEvidence(request(ledger))
        XCTAssertEqual(execution.result, .blocked)
        XCTAssertEqual(execution.cleanup, .noOwnedMutation)
        XCTAssertEqual(ledger.recordedCleanup, .noOwnedMutation)
        XCTAssertEqual(ledger.submissionCount, 0)
        XCTAssertEqual(access.preparations, 0)
        XCTAssertEqual(access.model.textReads, 0)
        XCTAssertTrue(access.model.selectionWrites.isEmpty)
    }

    @MainActor
    func testPreparationFailureDoesNotCreateAFalseSubmission() async {
        let access = AXSafetyTestAccess("ghbdtn ")
        access.preparationAllowed = false
        let ledger = ConversionSafetyLedger(generation: 2)
        let execution = await access.converter().performWithEvidence(request(ledger))
        XCTAssertEqual(execution.result, .failed)
        XCTAssertEqual(execution.cleanup, .noOwnedMutation)
        XCTAssertEqual(ledger.submissionCount, 0)
        XCTAssertTrue(access.replies.isEmpty)
        XCTAssertTrue(access.model.selectionWrites.isEmpty)
    }

    @MainActor
    func testAcceptedReceiverConfirmsConversionAndExactInverseWithNBSP() async throws {
        let access = AXSafetyTestAccess("😀 ghbdtn\u{00a0}")
        let first = ConversionSafetyLedger(generation: 3)
        access.beforeWrite = { token in
            XCTAssertEqual(token.operation, first.operation)
            XCTAssertTrue(first.hasEditorMutation, "Журнал обязан существовать до входа в receiver")
        }
        let forward = await access.converter().performWithEvidence(request(first))
        guard case .success(let receipt) = forward.result else { XCTFail("Нет подтверждённого результата"); return }
        XCTAssertEqual(receipt, .init(original: "ghbdtn", converted: "привет", trailingText: "\u{00a0}"))
        XCTAssertEqual(forward.cleanup, .recoveredObserved)
        XCTAssertEqual(first.submissionCount, 3)
        XCTAssertFalse(first.hasUnresolvedSubmissions)
        XCTAssertTrue(try XCTUnwrap(first.finishUsingRecordedCleanup(
            operation: first.operation, text: .confirmed, ordinaryRouteValid: true
        )).permitsConfirmedResult)
        let inverse = ConversionSafetyLedger(generation: 4)
        access.beforeWrite = { token in XCTAssertEqual(token.operation, inverse.operation) }
        let undone = await access.converter().performWithEvidence(ConversionRequest(
            expectedWord: receipt.converted, trailingText: receipt.trailingText, replacement: receipt.original,
            useSelection: false, safetyLedger: inverse
        ))
        XCTAssertEqual(undone.result, .success(.init(original: "привет", converted: "ghbdtn",
                                                  trailingText: "\u{00a0}")))
        XCTAssertTrue(access.model.value.utf16.elementsEqual("😀 ghbdtn\u{00a0}".utf16))
        XCTAssertEqual(inverse.recordedCleanup, .recoveredObserved)
        XCTAssertEqual(access.model.currentSelection, NSRange(location: access.model.value.utf16.count, length: 0))
    }

    @MainActor
    func testSuccessfulReturnAndObservedCaretCannotInventReceiverProof() async throws {
        let access = AXSafetyTestAccess("ghbdtn ")
        access.exposesCompletion = false
        let ledger = ConversionSafetyLedger(generation: 5)
        let execution = await access.converter().performWithEvidence(request(ledger))
        XCTAssertEqual(execution.result, .failed)
        XCTAssertEqual(execution.cleanup, .recoveredObserved)
        XCTAssertTrue(ledger.hasUnknownSubmissions)
        XCTAssertEqual(access.model.textWrites, 0)
        XCTAssertEqual(access.replies, [.success, .success])
        XCTAssertEqual(try XCTUnwrap(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: .unchangedByOperation, ordinaryRouteValid: true
        )).input, .recoveryRequired)
    }

    @MainActor
    func testErrorReturnMayHaveAppliedButNeverProducesReceipt() async throws {
        let access = AXSafetyTestAccess("ghbdtn ")
        access.firstSelectionStatus = .cannotComplete
        let ledger = ConversionSafetyLedger(generation: 6)
        let execution = await access.converter().performWithEvidence(request(ledger))
        XCTAssertEqual(execution.result, .failed)
        XCTAssertEqual(access.replies.first, .cannotComplete)
        XCTAssertEqual(access.model.selectionWrites.count, 2)
        XCTAssertEqual(access.model.textWrites, 0)
        XCTAssertTrue(ledger.encounteredUnknown)
        XCTAssertFalse(ledger.hasUnresolvedSubmissions, "Только отдельная модель receiver закрывает попытки")
        let decision = try XCTUnwrap(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: .unchangedByOperation, ordinaryRouteValid: true
        ))
        XCTAssertEqual(decision.input, .replayAuthorized)
        XCTAssertFalse(decision.permitsConfirmedResult)
    }

    @MainActor
    func testLateFirstSetterIsNotCancelledByObservedCleanupOfAnotherSetter() async throws {
        let access = AXSafetyTestAccess("ghbdtn ")
        access.deferFirstSelection = true
        access.firstSelectionStatus = .cannotComplete
        let ledger = ConversionSafetyLedger(generation: 7)
        let execution = await access.converter().performWithEvidence(request(ledger))
        XCTAssertEqual(execution.result, .failed)
        XCTAssertEqual(execution.cleanup, .recoveredObserved)
        XCTAssertTrue(ledger.hasUnknownSubmissions)
        XCTAssertEqual(access.model.currentSelection, NSRange(location: 7, length: 0))
        let decision = try XCTUnwrap(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: .unchangedByOperation, ordinaryRouteValid: true
        ))
        XCTAssertEqual(decision.input, .recoveryRequired)
        access.applyDelayedSelection()
        XCTAssertEqual(access.model.currentSelection, NSRange(location: 0, length: 7))
        XCTAssertEqual(ledger.decision, decision)
        XCTAssertEqual(access.model.textWrites, 0)
    }

    @MainActor
    func testPersistentMissingReadbackPreservesUnknownCleanup() async throws {
        let access = AXSafetyTestAccess("ghbdtn ")
        access.missingAfterSelection = true
        let ledger = ConversionSafetyLedger(generation: 8)
        let execution = await access.converter().performWithEvidence(request(ledger))
        XCTAssertEqual(execution.result, .failed)
        XCTAssertEqual(execution.cleanup, .recoveryUnconfirmed)
        XCTAssertEqual(ledger.recordedCleanup, .recoveryUnconfirmed)
        XCTAssertEqual(access.model.selectionWrites.count, 1)
        XCTAssertEqual(access.model.textWrites, 0)
        XCTAssertEqual(try XCTUnwrap(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: .unchangedByOperation, ordinaryRouteValid: true
        )).input, .recoveryRequired)
    }

    @MainActor
    func testForeignFocusOrProtectedFieldPreventsCleanupRPC() async {
        for protected in [false, true] {
            let access = AXSafetyTestAccess("ghbdtn ")
            access.afterWrite = {
                if protected { access.model.protected = true } else { access.model.changeFocusAfterSelection = true }
            }
            let ledger = ConversionSafetyLedger(generation: 9)
            let execution = await access.converter().performWithEvidence(request(ledger))
            XCTAssertEqual(execution.result, .blocked)
            XCTAssertEqual(execution.cleanup, .recoveryUnconfirmed)
            XCTAssertEqual(access.model.selectionWrites.count, 1)
            XCTAssertEqual(access.model.textWrites, 0)
        }
    }

    @MainActor
    func testCanonicalEquivalentForeignSnapshotIsNotExactCompletionEvidence() async {
        let prefix = "e\u{301}\u{327} "
        let foreign = "e\u{327}\u{301} "
        let access = AXSafetyTestAccess(prefix + "ghbdtn ")
        access.afterWrite = { access.model.value = foreign + "ghbdtn " }
        let ledger = ConversionSafetyLedger(generation: 10)
        let execution = await access.converter().performWithEvidence(request(ledger))
        XCTAssertEqual(execution.result, .failed)
        XCTAssertEqual(execution.cleanup, .recoveryUnconfirmed)
        XCTAssertEqual(access.model.textWrites, 0)
        XCTAssertEqual(access.model.selectionWrites.count, 1)
    }

    @MainActor
    func testCancelledTaskWithDefaultRequestValidityCannotSubmitFirstSetter() async {
        let access = AXSafetyTestAccess("ghbdtn ")
        let ledger = ConversionSafetyLedger(generation: 11)
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await access.converter().performWithEvidence(self.request(ledger))
        }
        let result = await operation.value
        XCTAssertTrue(operation.isCancelled)
        XCTAssertEqual(result.result, .blocked)
        XCTAssertEqual(ledger.submissionCount, 0)
        XCTAssertTrue(access.model.selectionWrites.isEmpty)
    }

    @MainActor
    func testCancellationAfterSelectionStopsTextButAllowsSeparateCleanup() async {
        let access = AXSafetyTestAccess("ghbdtn ")
        access.afterWrite = { withUnsafeCurrentTask { $0?.cancel() } }
        let ledger = ConversionSafetyLedger(generation: 12)
        let operation = Task { @MainActor in
            await access.converter().performWithEvidence(self.request(ledger))
        }
        let result = await operation.value
        XCTAssertTrue(operation.isCancelled)
        XCTAssertEqual(result.result, .blocked)
        XCTAssertEqual(result.cleanup, .recoveredObserved)
        XCTAssertEqual(access.model.textWrites, 0)
        XCTAssertEqual(access.model.selectionWrites, [NSRange(location: 0, length: 7), NSRange(location: 7, length: 0)])
        XCTAssertEqual(access.model.currentSelection, NSRange(location: 7, length: 0))
    }

    @MainActor
    func testSupersededFinalObservationCannotBorrowNewerCleanupForReceipt() async throws {
        try await assertSupersededFinalObservation(closesLedger: false)
    }

    @MainActor
    func testLedgerFinishedInsideFinalReadCannotPublishLateReceipt() async throws {
        try await assertSupersededFinalObservation(closesLedger: true)
    }

    @MainActor
    private func assertSupersededFinalObservation(closesLedger: Bool) async throws {
        let access = AXSafetyTestAccess("ghbdtn ")
        let ledger = ConversionSafetyLedger(generation: 13)
        var injected = false
        access.model.onTextRead = {
            guard !injected, ledger.submissionCount == 3, !ledger.hasUnresolvedSubmissions,
                  ledger.recordedCleanup == .recoveryUnconfirmed else { return }
            injected = true
            guard let newer = ledger.beginCleanupObservation(operation: ledger.operation) else {
                XCTFail("Вложенное наблюдение должно начаться до внешнего завершения")
                return
            }
            XCTAssertTrue(ledger.recordCleanup(.recoveredObserved, observation: newer))
            if closesLedger {
                XCTAssertNotNil(ledger.finishUsingRecordedCleanup(
                    operation: ledger.operation, text: .unknown, ordinaryRouteValid: false
                ))
            }
        }
        let execution = await access.converter().performWithEvidence(request(ledger))
        XCTAssertTrue(injected)
        XCTAssertEqual(execution.result, .failed)
        XCTAssertEqual(execution.cleanup, .recoveryUnconfirmed)
        XCTAssertEqual(access.model.selectionWrites.count, 2)
        XCTAssertEqual(access.model.textWrites, 1)
        XCTAssertEqual(ledger.recordedCleanup, .recoveredObserved, "Поздняя проверка не затирается старой")
        if closesLedger {
            XCTAssertEqual(ledger.decision?.input, .recoveryRequired)
            XCTAssertEqual(ledger.decision?.permitsConfirmedResult, false)
        } else {
            XCTAssertNil(ledger.decision)
        }
    }

    @MainActor
    private func request(_ ledger: ConversionSafetyLedger) -> ConversionRequest {
        ConversionRequest(expectedWord: "ghbdtn", trailingText: " ", sourceLayout: .english,
                          useSelection: false, safetyLedger: ledger)
    }
}
