@testable import LSwitchCore
import XCTest

extension ClipboardConverterTests {
    @MainActor
    func testDeferredRangeIsStableBeforePaste() async {
        let editor = ClipboardEditor(text: "цщкдв ")
        editor.rangeDelay = 2
        editor.beforeCommand = { command in
            if command == .paste {
                XCTAssertEqual(editor.selection, 0..<6)
                XCTAssertEqual(editor.sleeps, 3)
            }
        }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "цщкдв", trailingText: " ", sourceLayout: .russian, useSelection: false
        ))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "цщкдв", converted: "world", trailingText: " ")))
        XCTAssertTrue(editor.pendingRanges.isEmpty)
        editor.type("next")
        XCTAssertEqual(editor.text, "world next")
    }

    @MainActor
    func testRejectedDeferredRangeIsRestoredDespiteOriginalEarlyReadback() async {
        let editor = ClipboardEditor(text: "цщкдв ")
        editor.rangeDelay = 2
        editor.rangeWriteSucceeds = false
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "цщкдв", trailingText: " ", useSelection: false
        ))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.rangeWrites, [NSRange(location: 0, length: 6), NSRange(location: 6, length: 0)])
        XCTAssertTrue(editor.pendingRanges.isEmpty)
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.clipboard, "clipboard before")
        editor.type("next")
        XCTAssertEqual(editor.text, "цщкдв next")
    }

    @MainActor
    func testHoldCancellationRestoresPendingRangeBeforeReturning() async {
        let editor = ClipboardEditor(text: "цщкдв ")
        editor.rangeDelay = 2
        editor.onRangeWrite = { range in if range.length > 0 { editor.requestValid = false } }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "цщкдв", trailingText: " ", useSelection: false,
            canCleanup: { true }, isValid: { editor.requestValid }
        ))
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(editor.pendingRanges.isEmpty)
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.commands, [])
        editor.type("next")
        XCTAssertEqual(editor.text, "цщкдв next")
    }

    @MainActor
    func testScriptChangedTextOrSelectionDuringYieldIsNotOverwritten() async {
        for changeText in [false, true] {
            let editor = ClipboardEditor(text: "prefix ghbdtn ")
            editor.onSleep = { count in
                if count == 2 {
                    if changeText { editor.text = "script changed" }
                    editor.selection = 0..<3
                }
            }
            let result = await editor.converter().perform(ConversionRequest(
                expectedWord: "ghbdtn", trailingText: " ", useSelection: false
            ))
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(editor.commands, [])
            XCTAssertEqual(editor.rangeWrites.count, 1)
            XCTAssertEqual(editor.selection, 0..<3)
            XCTAssertEqual(editor.text, changeText ? "script changed" : "prefix ghbdtn ")
        }
    }
}
