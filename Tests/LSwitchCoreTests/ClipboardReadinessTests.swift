import Foundation
@testable import LSwitchCore
import XCTest

final class ClipboardReadinessTests: XCTestCase {
    @MainActor
    func testReadyAutomaticSnapshotSkipsBlindDelayAndReportsExactPhases() async {
        let editor = ClipboardEditor(text: "ghbdtn ")
        var phases: [ConversionDiagnostics.Phase] = []
        let diagnostics = ConversionDiagnostics(
            bundleID: "test.app", triggerTimestamp: 10, attempt: 1, automatic: true,
            now: { 20 }, emit: { phases.append($0.phase) }
        )
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", useSelection: false, diagnostics: diagnostics
        ))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.inputBarriers, 1)
        XCTAssertEqual(editor.sleepDelays, [0.02, 0.02])
        XCTAssertFalse(phases.contains(.preparationWaitEnded))
        XCTAssertEqual(phases.filter { measuredPhases.contains($0) }, measuredPhases)
        XCTAssertEqual(editor.diagnosticsBindings, [true, false])
    }

    @MainActor
    func testNotYetDeliveredDelimiterRetainsBoundedReadinessWait() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.onSleep = { count in if count == 1 { editor.type(" ") } }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", useSelection: false
        ))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.inputBarriers, 1)
        XCTAssertEqual(editor.sleepDelays, [0.02, 0.02, 0.02])
        XCTAssertEqual(editor.captures, 1)
        XCTAssertEqual(editor.text, "привет ")
    }

    @MainActor
    func testAlreadyQueuedInputInvalidationRunsBeforeSnapshotAndMutation() async {
        let editor = ClipboardEditor(text: "ghbdtn ")
        editor.onInputBarrier = {
            DispatchQueue.main.async { editor.requestValid = false }
            await ClipboardEnvironment.drainMainQueue()
        }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", useSelection: false, isValid: { editor.requestValid }
        ))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.stateReads, 0)
        XCTAssertEqual(editor.captures, 0)
        XCTAssertEqual(editor.writes, 0)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertTrue(editor.commands.isEmpty)
        XCTAssertTrue(editor.sleepDelays.isEmpty)
    }

    private var measuredPhases: [ConversionDiagnostics.Phase] {
        [
            .inputQueueDrained, .snapshotReadyWithoutDelay, .clipboardCaptureStarted, .clipboardCaptured,
            .clipboardWriteStarted, .clipboardWritten, .selectionSettled,
            .clipboardRestoreStarted, .clipboardRestored
        ]
    }
}
