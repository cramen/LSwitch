import Foundation
@testable import LSwitchCore
import XCTest

final class ClipboardSafetyTests: XCTestCase {
    @MainActor
    func testMissingBoundContractRefusesBeforePayloadCapturePreparationAndWrite() async {
        let editor = ClipboardSafetyEditor()
        editor.bound = false
        let ledger = ConversionSafetyLedger(generation: 1)
        let result = await editor.converter().perform(request(ledger))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.stateReads, 0)
        XCTAssertEqual(editor.preparations, 0)
        XCTAssertEqual(editor.captures, 0)
        XCTAssertEqual(editor.writes, 0)
        XCTAssertEqual(editor.selectionWrites, 0)
        XCTAssertTrue(editor.commands.isEmpty)
        XCTAssertEqual(ledger.submissionCount, 0)
        XCTAssertEqual(ledger.recordedCleanup, .noOwnedMutation)
    }

    @MainActor
    func testAcceptedReceiverPreservesExactTailAndUndo() async throws {
        let editor = ClipboardSafetyEditor("😀 ghbdtn\u{00a0}")
        let first = ConversionSafetyLedger(generation: 2)
        editor.onSubmit = { token in
            XCTAssertEqual(token.operation, first.operation)
            XCTAssertGreaterThan(first.submissionCount, 0)
        }
        let result = await editor.converter().perform(request(first, tail: "\u{00a0}"))
        guard case .success(let receipt) = result else { return XCTFail("Нет подтверждённой замены") }
        XCTAssertEqual(editor.text, "😀 привет\u{00a0}")
        XCTAssertEqual(editor.clipboard, "original clipboard")
        XCTAssertNil(first.decision, "Движок не владеет решением об очереди")
        XCTAssertEqual(first.recordedCleanup, .recoveredObserved)
        XCTAssertTrue(try XCTUnwrap(first.finishUsingRecordedCleanup(
            operation: first.operation, text: .confirmed, ordinaryRouteValid: true
        )).permitsConfirmedResult)
        let inverse = ConversionSafetyLedger(generation: 3)
        editor.onSubmit = { XCTAssertEqual($0.operation, inverse.operation) }
        let undone = await editor.converter().perform(ConversionRequest(
            expectedWord: receipt.converted, trailingText: receipt.trailingText, replacement: receipt.original,
            useSelection: false, safetyLedger: inverse
        ))
        guard case .success = undone else { return XCTFail("Точный inverse не подтверждён") }
        XCTAssertTrue(editor.text.utf16.elementsEqual("😀 ghbdtn\u{00a0}".utf16))
        XCTAssertEqual(editor.selection, NSRange(location: editor.text.utf16.count, length: 0))
    }

    @MainActor
    func testPersistentMissingReadbackForBothSelectionTransportsRequiresRecovery() async throws {
        for method in [ClipboardEnvironment.SelectionMethod.accessibility, .keyboard] {
            let editor = ClipboardSafetyEditor()
            editor.selectionMethod = method
            editor.missingAfterSelection = true
            let ledger = ConversionSafetyLedger(generation: 4)
            let result = await editor.converter().perform(request(ledger))
            XCTAssertEqual(result, .failed)
            XCTAssertFalse(editor.commands.contains(.paste))
            XCTAssertEqual(editor.selection, NSRange(location: 0, length: 7))
            XCTAssertEqual(editor.clipboard, "original clipboard")
            XCTAssertEqual(ledger.recordedCleanup, .recoveryUnconfirmed)
            XCTAssertEqual(try XCTUnwrap(ledger.finishUsingRecordedCleanup(
                operation: ledger.operation, text: .unchangedByOperation, ordinaryRouteValid: true
            )).input, .recoveryRequired)
        }
    }

    @MainActor
    func testUnresolvedCopyNeverRetriesOrWritesReplacement() async throws {
        let editor = ClipboardSafetyEditor("ghbdtn")
        editor.selection = NSRange(location: 0, length: 6)
        editor.unconfirmedKinds = [.copy]
        let ledger = ConversionSafetyLedger(generation: 5)
        let result = await editor.converter(forceCopy: true).perform(ConversionRequest(
            sourceLayout: .english, useSelection: true, safetyLedger: ledger
        ))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [.copy])
        XCTAssertEqual(editor.writes, 0)
        XCTAssertEqual(editor.clipboard, "original clipboard")
        XCTAssertEqual(editor.restores, 1)
        XCTAssertTrue(ledger.hasUnknownSubmissions)
        XCTAssertEqual(ledger.recordedCleanup, .noOwnedMutation)
        XCTAssertEqual(try XCTUnwrap(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: .unchangedByOperation, ordinaryRouteValid: true
        )).input, .recoveryRequired)
    }

    @MainActor
    func testFailureBeforePasteDoesNotInventTextSubmission() async {
        let editor = ClipboardSafetyEditor()
        editor.failBeforePaste = true
        let ledger = ConversionSafetyLedger(generation: 6)
        let transaction = makeTransaction(editor, ledger)
        let result = await transaction.run()
        XCTAssertEqual(result, .failed)
        XCTAssertFalse(transaction.pasted)
        XCTAssertFalse(editor.commands.contains(.paste))
        XCTAssertEqual(editor.selection.length, 0)
        XCTAssertEqual(ledger.recordedCleanup, .recoveredObserved)
    }

    @MainActor
    func testDelayedSetterRemainsUnknownDespiteSeparateObservedCleanup() async throws {
        let editor = ClipboardSafetyEditor()
        editor.deferFirstSelection = true
        editor.selectionStatus = .cannotComplete
        let ledger = ConversionSafetyLedger(generation: 7)
        let result = await editor.converter().perform(request(ledger))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.selection.length, 0)
        XCTAssertEqual(ledger.recordedCleanup, .recoveredObserved)
        let decision = try XCTUnwrap(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: .unchangedByOperation, ordinaryRouteValid: true
        ))
        XCTAssertEqual(decision.input, .recoveryRequired)
        let delayed = try XCTUnwrap(editor.deferredSelection)
        editor.selection = delayed.range
        editor.completed.insert(delayed.token)
        XCTAssertEqual(ledger.decision, decision)
        XCTAssertFalse(editor.commands.contains(.paste))
    }

    @MainActor
    func testForeignClipboardWriteIsNeverRestored() async {
        let editor = ClipboardSafetyEditor()
        editor.onWrite = { editor.clipboard = "foreign copy"; editor.count += 1 }
        let ledger = ConversionSafetyLedger(generation: 8)
        let result = await editor.converter().perform(request(ledger))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.clipboard, "foreign copy")
        XCTAssertEqual(editor.restores, 0)
        XCTAssertEqual(ledger.submissionCount, 0)
    }

    @MainActor
    func testNestedFinalObservationCannotResurrectOuterReceipt() async {
        for closeLedger in [false, true] {
            let editor = ClipboardSafetyEditor()
            let ledger = ConversionSafetyLedger(generation: 9)
            var nested = false
            editor.onRead = {
                guard !nested, editor.commands.contains(.paste), ledger.recordedCleanup == .recoveryUnconfirmed,
                      let ticket = ledger.beginCleanupObservation(operation: ledger.operation) else { return }
                nested = true
                XCTAssertTrue(ledger.recordCleanup(.recoveredObserved, observation: ticket))
                if closeLedger {
                    _ = ledger.finishUsingRecordedCleanup(
                        operation: ledger.operation, text: .unknown, ordinaryRouteValid: false
                    )
                }
            }
            let result = await editor.converter().perform(request(ledger))
            XCTAssertTrue(nested)
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(editor.text, "привет ")
        }
    }

    @MainActor
    func testErrorAfterAppliedSelectionCannotBecomeSuccessfulReceipt() async {
        let editor = ClipboardSafetyEditor()
        editor.selectionStatus = .cannotComplete
        let ledger = ConversionSafetyLedger(generation: 10)
        let result = await editor.converter().perform(request(ledger))
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(ledger.encounteredUnknown)
        XCTAssertFalse(ledger.hasUnresolvedSubmissions, "Модель отдельно подтверждает выполненный setter")
        XCTAssertEqual(ledger.recordedCleanup, .recoveredObserved)
        XCTAssertFalse(editor.commands.contains(.paste))
    }

    @MainActor
    func testCanonicalForeignPrefixAfterPasteNeverAuthorizesCleanupMutation() async {
        let originalPrefix = "e\u{301}\u{327} "
        let foreignPrefix = "e\u{327}\u{301} "
        XCTAssertEqual(originalPrefix, foreignPrefix)
        for method in [ClipboardEnvironment.SelectionMethod.accessibility, .keyboard] {
            let editor = ClipboardSafetyEditor(originalPrefix + "ghbdtn ")
            editor.keepPastedSelection = true
            editor.selectionMethod = method
            editor.onRead = {
                if editor.commands.contains(.paste) { editor.text = foreignPrefix + "привет " }
            }
            let ledger = ConversionSafetyLedger(generation: 11)
            let result = await editor.converter().perform(request(ledger))
            XCTAssertEqual(result, .failed)
            XCTAssertTrue(editor.text.utf16.elementsEqual((foreignPrefix + "привет ").utf16))
            XCTAssertEqual(editor.selection, NSRange(location: originalPrefix.utf16.count, length: 7))
            XCTAssertEqual(editor.selectionWrites, method == .accessibility ? 1 : 0)
            XCTAssertFalse(editor.commands.contains(.collapseSelection))
            XCTAssertEqual(editor.commands.filter { $0 == .paste }.count, 1)
            XCTAssertEqual(ledger.recordedCleanup, .recoveryUnconfirmed)
            XCTAssertEqual(editor.clipboard, "original clipboard")
        }
    }

    @MainActor
    func testNilLedgerPreservesExistingVerifiedPath() async {
        let editor = ClipboardEditor(text: "ghbdtn ")
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", sourceLayout: .english, useSelection: false
        ))
        XCTAssertEqual(result, .success(.init(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.text, "привет ")
        XCTAssertEqual(editor.clipboard, "clipboard before")
        XCTAssertEqual(editor.commands, [.paste])
    }

    @MainActor
    private func request(_ ledger: ConversionSafetyLedger, tail: String = " ") -> ConversionRequest {
        ConversionRequest(expectedWord: "ghbdtn", trailingText: tail, sourceLayout: .english,
                          useSelection: false, safetyLedger: ledger)
    }

    @MainActor
    private func makeTransaction(_ editor: ClipboardSafetyEditor, _ ledger: ConversionSafetyLedger)
        -> ClipboardTransaction {
        ClipboardTransaction(request: request(ledger), configuration: .init(), environment: editor.environment(),
                             transform: nil)
    }
}
