import Foundation
@testable import LSwitchCore
import XCTest

final class ClipboardDiagnosticsTests: XCTestCase {
    @MainActor
    func testFocusIdentityChangeDuringPreparationHasExactReasonWithoutMutation() async {
        let editor = ClipboardEditor(text: "ghbdtn ")
        var failure: ConversionDiagnostics.Rejection?
        editor.safetyFailure = { failure }
        editor.onPrepare = { failure = .focusedElementChanged }
        var samples: [ConversionDiagnostics.Sample] = []
        let diagnostics = trace { samples.append($0) }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", useSelection: false, diagnostics: diagnostics
        ))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(samples.last?.reason, .focusedElementChanged)
        XCTAssertTrue(samples.contains { $0.phase == .inputQueueDrained })
        XCTAssertFalse(samples.contains { $0.phase == .snapshotRead })
        XCTAssertEqual(editor.captures, 0)
        XCTAssertEqual(editor.writes, 0)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertTrue(editor.commands.isEmpty)
    }

    @MainActor
    func testMismatchedSnapshotIsDifferentFromUnavailableSnapshot() async {
        for available in [true, false] {
            let editor = ClipboardEditor(text: "different ")
            editor.exposesState = available
            var samples: [ConversionDiagnostics.Sample] = []
            let diagnostics = trace { samples.append($0) }
            let result = await editor.converter().perform(ConversionRequest(
                expectedWord: "ghbdtn", trailingText: " ", useSelection: false, diagnostics: diagnostics
            ))
            XCTAssertEqual(result, .blocked)
            XCTAssertEqual(samples.last?.reason, available ? .expectedSpanMismatch : .snapshotUnavailable)
            XCTAssertEqual(editor.writes, 0)
            XCTAssertTrue(editor.commands.isEmpty)
        }
    }

    @MainActor
    func testLaggingCaretAndUnexpectedSelectionAreDistinguishedBeforeMutation() async {
        for selected in [false, true] {
            let editor = ClipboardEditor(text: selected ? "ghbdtn" : "")
            if selected { editor.selection = 0..<6 }
            var samples: [ConversionDiagnostics.Sample] = []
            let diagnostics = trace { samples.append($0) }
            let result = await editor.converter().perform(ConversionRequest(
                expectedWord: "ghbdtn", useSelection: false, diagnostics: diagnostics
            ))
            XCTAssertEqual(result, .blocked)
            XCTAssertEqual(samples.last?.reason, selected ? .unexpectedSelection : .caretBeforeExpectedSpan)
            XCTAssertEqual(editor.captures, 0)
            XCTAssertEqual(editor.writes, 0)
            XCTAssertTrue(editor.rangeWrites.isEmpty)
        }
    }

    @MainActor
    func testNonrestorableClipboardBlocksVerifiedAndLegacyPathsBeforeAnyMutation() async {
        let snapshots = [
            PasteboardSnapshot(items: [.init(dataByType: ["promised": nil])]),
            PasteboardSnapshot(items: [.init(dataByType: ["file": Data([1])])], containsFilePromises: true)
        ]
        for snapshot in snapshots {
            for legacy in [false, true] {
                let editor = ClipboardEditor(text: "ghbdtn")
                editor.initialStateUnavailable = legacy
                editor.snapshotOverride = snapshot
                var samples: [ConversionDiagnostics.Sample] = []
                let diagnostics = trace { samples.append($0) }
                let result = await editor.converter().perform(ConversionRequest(
                    expectedWord: "ghbdtn", diagnostics: diagnostics
                ))
                XCTAssertEqual(result, .blocked)
                XCTAssertEqual(samples.last?.reason, .clipboardNotRestorable)
                XCTAssertEqual(editor.captures, 1)
                XCTAssertEqual(editor.writes, 0)
                XCTAssertEqual(editor.restores, 0)
                XCTAssertTrue(editor.commands.isEmpty)
                XCTAssertTrue(editor.rangeWrites.isEmpty)
                XCTAssertEqual(editor.clipboard, "clipboard before")
                XCTAssertEqual(editor.text, "ghbdtn")
            }
        }
    }

    #if DEBUG
    @MainActor
    func testForcedCopyAcceptancePathStillReadsAndConfirmsState() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        var configuration = ClipboardConverter.Configuration()
        configuration.forceCopyForAcceptance = true
        let result = await editor.converter(configuration: configuration).perform(ConversionRequest(
            expectedWord: "ghbdtn"
        ))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет")))
        XCTAssertEqual(editor.commands, [.selectCharacters(6), .copy, .paste])
        XCTAssertGreaterThan(editor.stateReads, 0)
        XCTAssertEqual(editor.text, "привет")
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.clipboard, "clipboard before")
    }
    #endif

    @MainActor
    private func trace(_ emit: @escaping (ConversionDiagnostics.Sample) -> Void) -> ConversionDiagnostics {
        ConversionDiagnostics(
            bundleID: "test.app", triggerTimestamp: 10, attempt: 1, automatic: true, now: { 20 }, emit: emit
        )
    }
}
