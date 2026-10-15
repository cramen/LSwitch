import Foundation
@testable import LSwitchCore
import XCTest

final class UnicodeSafetyTests: XCTestCase {
    @MainActor
    func testUnboundReceiverRefusesBeforeSnapshotPreparationAndMutation() async {
        let editor = UnicodeSafetyEditor()
        editor.exposesContract = false
        let ledger = ConversionSafetyLedger(generation: 1)
        let result = await editor.converter().perform(request(ledger))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.reads, 0)
        XCTAssertEqual(editor.prepares, 0)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertTrue(editor.commands.isEmpty)
        XCTAssertEqual(ledger.recordedCleanup, .noOwnedMutation)
        XCTAssertEqual(ledger.submissionCount, 0)
    }

    @MainActor
    func testKnownUnavailableBalanceRefusesBeforeFirstDownOrSelection() async {
        let editor = UnicodeSafetyEditor()
        editor.balanceAllowed = false
        let ledger = ConversionSafetyLedger(generation: 14)
        let result = await editor.converter().perform(request(ledger))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.reads, 0)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertTrue(editor.commands.isEmpty)
        XCTAssertFalse(ledger.hasOutstandingKeyDebt)
    }

    @MainActor
    func testHealthyReceiverConfirmsExactInverseAndDoesNotFinishLedger() async throws {
        let editor = UnicodeSafetyEditor("😀 ghbdtn\u{00a0}")
        let ledger = ConversionSafetyLedger(generation: 2)
        let result = await editor.converter().perform(request(ledger, tail: "\u{00a0}"))
        guard case .success(let receipt) = result else { return XCTFail("Нет подтверждённой замены") }
        XCTAssertEqual(editor.text, "😀 привет\u{00a0}")
        XCTAssertEqual(editor.downCount, 1)
        XCTAssertEqual(editor.upCount, 1)
        XCTAssertEqual(ledger.recordedCleanup, .recoveredObserved)
        XCTAssertNil(ledger.decision)
        XCTAssertTrue(try XCTUnwrap(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: .confirmed, ordinaryRouteValid: true
        )).permitsConfirmedResult)
        let inverse = ConversionSafetyLedger(generation: 3)
        let undone = await editor.converter().perform(ConversionRequest(
            expectedWord: receipt.converted, trailingText: receipt.trailingText, replacement: receipt.original,
            useSelection: false, safetyLedger: inverse
        ))
        guard case .success = undone else { return XCTFail("Нет точного inverse") }
        XCTAssertTrue(editor.text.utf16.elementsEqual("😀 ghbdtn\u{00a0}".utf16))
        XCTAssertEqual(editor.selection, NSRange(location: editor.text.utf16.count, length: 0))
    }

    @MainActor
    func testPersistentCountIncoherenceAfterOwnSelectionRequiresRecovery() async throws {
        let editor = UnicodeSafetyEditor()
        editor.onSelect = { editor.characterCount = 999 }
        let ledger = ConversionSafetyLedger(generation: 4)
        let result = await editor.converter().perform(request(ledger))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.commands, [.select(7)])
        XCTAssertEqual(editor.selection, NSRange(location: 0, length: 7))
        XCTAssertEqual(ledger.recordedCleanup, .recoveryUnconfirmed)
        XCTAssertEqual(try decision(ledger).input, .recoveryRequired)
    }

    @MainActor
    func testPartialAndIgnoredSelectionNeverEmitUnicodeDown() async {
        for partial in [false, true] {
            let editor = UnicodeSafetyEditor()
            editor.partialSelection = partial
            editor.ignoreSelection = !partial
            let ledger = ConversionSafetyLedger(generation: 5)
            let result = await editor.converter().perform(request(ledger))
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(editor.downCount, 0)
            XCTAssertEqual(editor.text, "ghbdtn ")
            XCTAssertEqual(editor.selection.length, 0)
            XCTAssertEqual(ledger.recordedCleanup, .recoveredObserved)
            XCTAssertFalse(ledger.hasUnresolvedSubmissions)
        }
    }

    @MainActor
    func testIgnoredRightDoesNotTurnObservedSelectionIntoRecoveredCaret() async throws {
        let editor = UnicodeSafetyEditor()
        editor.ignoreCollapse = true
        editor.unconfirmedKinds = [.selection]
        let ledger = ConversionSafetyLedger(generation: 6)
        let result = await editor.converter().perform(request(ledger))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.commands, [.select(7), .collapse])
        XCTAssertEqual(ledger.recordedCleanup, .recoveryUnconfirmed)
        XCTAssertEqual(try decision(ledger).input, .recoveryRequired)
    }

    @MainActor
    func testLateNativeBatchCannotBeClosedByCachedOriginalCaret() async throws {
        let editor = UnicodeSafetyEditor()
        editor.selectionDelay = 100
        let ledger = ConversionSafetyLedger(generation: 7)
        let result = await editor.converter().perform(request(ledger))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(ledger.recordedCleanup, .recoveredObserved)
        XCTAssertTrue(ledger.hasUnknownSubmissions)
        let final = try decision(ledger)
        XCTAssertEqual(final.input, .recoveryRequired)
        editor.applyDelayed()
        XCTAssertEqual(ledger.decision, final)
    }

    @MainActor
    func testIgnoredAndPartialUnicodePacketsDoNotCreateReceiptOrRetry() async {
        for insertion in [UnicodeSafetyEditor.Insertion.ignored, .partial] {
            let editor = UnicodeSafetyEditor()
            editor.insertion = insertion
            let ledger = ConversionSafetyLedger(generation: 8)
            let result = await editor.converter().perform(request(ledger))
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(editor.downCount, 1)
            XCTAssertEqual(editor.upCount, 1)
            XCTAssertEqual(ledger.recordedCleanup,
                           insertion == .ignored ? .recoveredObserved : .recoveryUnconfirmed)
        }
    }

    @MainActor
    func testCancellationBeforeDownKeepsIndependentCleanup() async {
        let editor = UnicodeSafetyEditor()
        let ledger = ConversionSafetyLedger(generation: 9)
        var task: Task<ConversionResult, Never>?
        editor.onPause = { task?.cancel() }
        task = Task { await editor.converter().perform(self.request(ledger)) }
        let result = await task?.value
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.selection.length, 0)
        XCTAssertEqual(ledger.recordedCleanup, .recoveredObserved)
    }

    @MainActor
    func testCancellationAfterDownBalancesSamePacketAndNeverReturnsSuccess() async {
        let editor = UnicodeSafetyEditor()
        editor.insertion = .selected
        let ledger = ConversionSafetyLedger(generation: 10)
        var task: Task<ConversionResult, Never>?
        editor.onDown = { task?.cancel() }
        task = Task { await editor.converter().perform(self.request(ledger)) }
        let result = await task?.value
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.downCount, 1)
        XCTAssertEqual(editor.upCount, 1)
        XCTAssertEqual(editor.selection.length, 0)
        XCTAssertEqual(ledger.recordedCleanup, .recoveredObserved)
    }

    @MainActor
    func testObservedSelectionWithoutIndependentCompletionCannotAuthorizeUnicodeDown() async throws {
        let editor = UnicodeSafetyEditor()
        editor.unconfirmedKinds = [.selection]
        let ledger = ConversionSafetyLedger(generation: 11)
        let result = await editor.converter().perform(request(ledger))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.selection.length, 0)
        XCTAssertEqual(ledger.recordedCleanup, .recoveredObserved)
        XCTAssertEqual(try decision(ledger).input, .recoveryRequired)
    }

    @MainActor
    func testMissingUpRemainsRecoveryEvenWhenConvertedTextAndCaretAreExact() async throws {
        let editor = UnicodeSafetyEditor()
        editor.onDown = { editor.balanceAllowed = false }
        let ledger = ConversionSafetyLedger(generation: 12)
        let result = await editor.converter().perform(request(ledger))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.text, "привет ")
        XCTAssertEqual(editor.selection.length, 0)
        XCTAssertEqual(editor.downCount, 1)
        XCTAssertEqual(editor.upCount, 0)
        XCTAssertTrue(ledger.hasOutstandingKeyDebt)
        XCTAssertEqual(try decision(ledger).input, .recoveryRequired)
    }

    @MainActor
    func testNestedFinalObservationCannotUpgradeSupersededUnicodeReceipt() async {
        let editor = UnicodeSafetyEditor()
        let ledger = ConversionSafetyLedger(generation: 13)
        var nested = false
        editor.onRead = {
            guard !nested, editor.downCount > 0, ledger.recordedCleanup == .recoveryUnconfirmed,
                  let ticket = ledger.beginCleanupObservation(operation: ledger.operation) else { return }
            nested = true
            _ = ledger.recordCleanup(.recoveredObserved, observation: ticket)
            _ = ledger.finishUsingRecordedCleanup(
                operation: ledger.operation, text: .unknown, ordinaryRouteValid: false
            )
        }
        let result = await editor.converter().perform(request(ledger))
        XCTAssertTrue(nested)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.downCount, 1)
    }

    @MainActor
    private func request(_ ledger: ConversionSafetyLedger, tail: String = " ") -> ConversionRequest {
        .init(expectedWord: "ghbdtn", trailingText: tail, sourceLayout: .english,
              useSelection: false, safetyLedger: ledger)
    }

    @MainActor
    private func decision(_ ledger: ConversionSafetyLedger) throws -> ConversionSafetyDecision {
        try XCTUnwrap(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: .unknown, ordinaryRouteValid: true
        ))
    }
}
