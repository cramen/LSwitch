@testable import LSwitchCore
import XCTest

extension ClipboardConverterTests {
    @MainActor
    func testVerifiedMutationGuardRefusalDoesNotChangeTextOrSelection() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", useSelection: false, beginMutation: { false }
        ))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.rangeWrites, [])
        XCTAssertEqual(editor.text, "ghbdtn")
        XCTAssertEqual(editor.clipboard, "clipboard before")
        XCTAssertNil(editor.selection)
    }

    @MainActor
    func testMutationGuardRefusalPreservesExistingUserSelection() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.selection = 0..<6
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", beginMutation: { false }
        ))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.rangeWrites, [])
        XCTAssertEqual(editor.selection, 0..<6)
        XCTAssertEqual(editor.text, "ghbdtn")
        XCTAssertEqual(editor.clipboard, "clipboard before")
    }

    @MainActor
    func testLegacyMutationGuardRefusalPreventsSelectionAndCopy() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.initialStateUnavailable = true
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", beginMutation: { false }
        ))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.rangeWrites, [])
        XCTAssertEqual(editor.writes, 0)
        XCTAssertEqual(editor.text, "ghbdtn")
        XCTAssertEqual(editor.clipboard, "clipboard before")
    }

    @MainActor
    func testVerifiedMutationGuardRunsBeforeAXSelectionAndPaste() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.onRangeWrite = { range in
            if range.length > 0 { editor.mutationEvents.append("selection") }
        }
        editor.beforeCommand = { command in
            if command == .paste { editor.mutationEvents.append("paste") }
        }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", useSelection: false, beginMutation: {
                editor.mutationEvents.append("begin")
                return true
            }
        ))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет")))
        XCTAssertEqual(editor.mutationEvents, ["begin", "selection", "paste"])
    }

    @MainActor
    func testLegacyMutationGuardRunsBeforeSelectionCopyAndPaste() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.initialStateUnavailable = true
        editor.beforeCommand = { command in
            switch command {
            case .selectCharacters: editor.mutationEvents.append("selection")
            case .copy: editor.mutationEvents.append("copy")
            case .paste: editor.mutationEvents.append("paste")
            default: break
            }
        }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", beginMutation: {
                editor.mutationEvents.append("begin")
                return true
            }
        ))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет")))
        XCTAssertEqual(editor.mutationEvents, ["begin", "selection", "copy", "paste"])
    }
}
