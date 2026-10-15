@testable import LSwitchCore
import XCTest

extension ClipboardConverterTests {
    @MainActor
    func testExpiredLeaseRestoresObservedPartialAXSelectionBeforeReturning() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.onRangeWrite = { range in
            if range.length > 0 {
                editor.selection = 0..<5
                editor.requestValid = false
            }
        }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", useSelection: false,
            canCleanup: { true }, isValid: { editor.requestValid }
        ))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.text, "ghbdtn")
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.cursor, 6)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.rangeWrites, [NSRange(location: 0, length: 6), NSRange(location: 6, length: 0)])
    }

    @MainActor
    func testExpiredLeaseCollapsesRecognizableInsertedSelection() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.keepPastedSelection = true
        editor.afterCommand = { command in if command == .paste { editor.requestValid = false } }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", useSelection: false,
            canCleanup: { true }, isValid: { editor.requestValid }
        ))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.text, "привет")
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.commands, [.paste])
        XCTAssertEqual(editor.cursor, 6)
    }

    @MainActor
    func testLeaseExpiryDuringConfirmationStillCleansSelection() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.keepPastedSelection = true
        editor.onReadState = { _ in
            if editor.commands.contains(.paste) { editor.requestValid = false }
        }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", useSelection: false,
            canCleanup: { true }, isValid: { editor.requestValid }
        ))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.text, "привет")
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.commands, [.paste])
    }

    @MainActor
    func testExpiredLegacyLeaseCleansOnlyItsKnownSelectionWithoutPasting() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.initialStateUnavailable = true
        editor.afterCommand = { command in if command == .copy { editor.requestValid = false } }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", canCleanup: { true }, isValid: { editor.requestValid }
        ))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.text, "ghbdtn")
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.commands, [.selectCharacters(6), .copy, .collapseSelection])
    }

    @MainActor
    func testRevokedCleanupGrantDoesNotTouchSelectionAfterCancellation() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.onRangeWrite = { range in if range.length > 0 { editor.requestValid = false } }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", useSelection: false,
            canCleanup: { false }, isValid: { editor.requestValid }
        ))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.rangeWrites, [NSRange(location: 0, length: 6)])
        XCTAssertEqual(editor.selection, 0..<6)
        XCTAssertEqual(editor.commands, [])
    }

    @MainActor
    func testChangedTargetOverridesCleanupGrant() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.onRangeWrite = { range in
            if range.length > 0 { editor.current = false }
        }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", useSelection: false, canCleanup: { true }
        ))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.rangeWrites, [NSRange(location: 0, length: 6)])
        XCTAssertEqual(editor.commands, [])
    }
}
