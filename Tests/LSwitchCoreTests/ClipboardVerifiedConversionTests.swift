@testable import LSwitchCore
import XCTest

extension ClipboardConverterTests {
    @MainActor
    func testVerifiedSnapshotConvertsWithoutCopy() async {
        let editor = ClipboardEditor(text: "🙂 ghbdtn ")
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", useSelection: false
        ))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.commands, [.paste])
        XCTAssertEqual(editor.rangeWrites, [NSRange(location: 3, length: 7)])
        XCTAssertEqual(editor.text, "🙂 привет ")
        XCTAssertEqual(editor.clipboard, "clipboard before")
    }

    @MainActor
    func testVerifiedSnapshotInvalidatedAfterClipboardWriteDoesNotSelect() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.onWrite = { editor.requestValid = false }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", useSelection: false, isValid: { editor.requestValid }
        ))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.text, "ghbdtn")
        XCTAssertEqual(editor.clipboard, "clipboard before")
    }

    @MainActor
    func testChangedSnapshotCancelsBeforeSelection() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.onWrite = { editor.type("x") }
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", useSelection: false))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.text, "ghbdtnx")
        XCTAssertEqual(editor.clipboard, "clipboard before")
    }

    @MainActor
    func testMismatchedReadableSnapshotDoesNotTouchClipboardOrSelection() async {
        let editor = ClipboardEditor(text: "other")
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", useSelection: false))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.captures, 0)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.text, "other")
    }

    @MainActor
    func testAutomaticConversionWithoutAXSnapshotDoesNotSelect() async {
        let editor = ClipboardEditor(text: "ghbdtn ")
        editor.exposesState = false
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", useSelection: false
        ))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.captures, 0)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.clipboard, "clipboard before")
    }

    @MainActor
    func testMissingSynchronousPasteDoesNotCreateSelection() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.commitAvailable = false
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", useSelection: false))
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.text, "ghbdtn")
        XCTAssertEqual(editor.clipboard, "clipboard before")
    }
}

extension ClipboardConverterTests {
    @MainActor
    func testAXSelectionNoOpNeverPastesOrQueuesArrows() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.rangeWriteApplies = false
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", useSelection: false))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.rangeWrites, [NSRange(location: 0, length: 6)])
        XCTAssertEqual(editor.text, "ghbdtn")
        XCTAssertEqual(editor.cursor, 6)
        XCTAssertNil(editor.selection)
        editor.type(" next")
        XCTAssertEqual(editor.text, "ghbdtn next")
    }

    @MainActor
    func testUnconfirmedExistingSelectionIsPreserved() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.selection = 0..<6
        editor.onReadState = { count in
            if count == 3 { editor.stateOverride = (editor.text, NSRange(location: 0, length: 0)) }
        }
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.selection, 0..<6)
        XCTAssertEqual(editor.text, "ghbdtn")
    }

    @MainActor
    func testMissingAXEvidenceDoesNotClaimSuccessfulPaste() async {
        for selectedTextAvailable in [true, false] {
            let editor = ClipboardEditor(text: "ghbdtn")
            editor.exposesState = false
            editor.selectedTextAvailable = selectedTextAvailable
            editor.rejectPaste = true
            editor.rejectedPasteClearsSelection = true
            let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(editor.text, "ghbdtn")
            XCTAssertEqual(editor.clipboard, "clipboard before")
        }
    }

    @MainActor
    func testExternalClipboardWriteDuringOwnWriteIsNotClaimedOrRestored() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.onWrite = { editor.updateClipboard("new user clipboard") }
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", useSelection: false))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.restores, 0)
        XCTAssertEqual(editor.clipboard, "new user clipboard")
        XCTAssertEqual(editor.text, "ghbdtn")
    }
}

extension ClipboardConverterTests {
    @MainActor
    func testAXRangeNotSettableDoesNotPaste() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.rangeSettable = false
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", useSelection: false))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.rangeWrites, [])
        XCTAssertEqual(editor.text, "ghbdtn")
    }

    @MainActor
    func testAppliedRangeWithReportedErrorRestoresExactOriginalCaret() async {
        let editor = ClipboardEditor(text: "🙂 ghbdtn")
        editor.rangeWriteSucceeds = false
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", useSelection: false))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.rangeWrites, [NSRange(location: 3, length: 6), NSRange(location: 9, length: 0)])
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.cursor, 8)
        XCTAssertEqual(editor.text, "🙂 ghbdtn")
    }

    @MainActor
    func testRejectedAXSelectionDoesNotRestoreOverForeignRange() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.onRangeWrite = { range in if range.length > 0 { editor.selection = 0..<5 } }
        editor.onReadState = { count in if count == 5 { editor.selection = 1..<3 } }
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", useSelection: false))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.rangeWrites, [NSRange(location: 0, length: 6)])
        XCTAssertEqual(editor.selection, 1..<3)
    }

    @MainActor
    func testMissingSelectionReadbackDoesNotConfirmIgnoredCollapse() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.exposesState = false
        editor.keepPastedSelection = true
        editor.ignoreCollapseSelection = true
        editor.afterCommand = { command in
            if command == .collapseSelection { editor.selectedTextAvailable = false }
        }
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.selection, 0..<6)
        XCTAssertEqual(editor.text, "привет")
    }
}

extension ClipboardConverterTests {
    @MainActor
    func testClampedAXRangeRestoresOriginalCaretForSuccessAndError() async {
        for reportedSuccess in [true, false] {
            let editor = ClipboardEditor(text: "ghbdtn ")
            editor.rangeWriteSucceeds = reportedSuccess
            editor.onRangeWrite = { range in if range.length > 0 { editor.selection = 0..<6 } }
            let result = await editor.converter().perform(ConversionRequest(
                expectedWord: "ghbdtn", trailingText: " ", useSelection: false
            ))
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(editor.commands, [])
            XCTAssertEqual(editor.rangeWrites, [NSRange(location: 0, length: 7), NSRange(location: 7, length: 0)])
            XCTAssertEqual(editor.cursor, 7)
            XCTAssertNil(editor.selection)
            XCTAssertEqual(editor.text, "ghbdtn ")
        }
    }

    @MainActor
    func testPasteErrorAfterAppliedReplacementCollapsesRecognizableSelection() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.keepPastedSelection = true
        editor.commitReportsFailure = true
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", useSelection: false))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [.paste])
        XCTAssertEqual(editor.text, "привет")
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.cursor, 6)
        XCTAssertEqual(editor.rangeWrites, [NSRange(location: 0, length: 6), NSRange(location: 6, length: 0)])
    }
}
