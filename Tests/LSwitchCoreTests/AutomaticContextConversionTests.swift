import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class AutomaticContextConversionTests: XCTestCase {
    func testAXCodeRefusalPrecedesSelectionAndWrite() async {
        let access = FakeAXTextAccess(text: "let ghbdtn ")
        access.documentContext = source(access.value)
        let result = await performAX(access)
        XCTAssertEqual(result, .blocked)
        XCTAssertTrue(access.selectionWrites.isEmpty)
        XCTAssertEqual(access.textWrites, 0)
        XCTAssertEqual(access.value, "let ghbdtn ")
    }

    func testAXCommentsAndStringsStillConvert() async {
        for prefix in ["// ", "let message = \""] {
            let access = FakeAXTextAccess(text: prefix + "ghbdtn ")
            access.documentContext = source(access.value)
            let result = await performAX(access)
            XCTAssertEqual(result, success)
            XCTAssertEqual(access.value, prefix + "привет ")
            XCTAssertEqual(access.currentSelection, NSRange(location: access.value.utf16.count, length: 0))
        }
    }

    func testClipboardCodeRefusalPrecedesCaptureSelectionAndWrite() async {
        let editor = ClipboardEditor(text: "let ghbdtn ")
        editor.documentContext = source(editor.text)
        let result = await editor.converter().perform(automatic)
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.captures, 0)
        XCTAssertEqual(editor.writes, 0)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertTrue(editor.commands.isEmpty)
    }

    func testClipboardCommentsAndStringsStillConvert() async {
        for prefix in ["// ", "let message = \""] {
            let editor = ClipboardEditor(text: prefix + "ghbdtn ")
            editor.documentContext = source(editor.text)
            let result = await editor.converter().perform(automatic)
            XCTAssertEqual(result, success)
            XCTAssertEqual(editor.text, prefix + "привет ")
            XCTAssertEqual(editor.captures, 1)
            XCTAssertEqual(editor.restores, 1)
        }
    }

    func testUnknownAndTruncatedSourceRefuseBothTransports() async {
        for context in [AutomaticTextContext.unknown, .source(
            language: .swift, document: "file:///test.swift", characterCount: 999
        )] {
            let access = FakeAXTextAccess(text: "// ghbdtn ")
            access.documentContext = context
            let converted = await performAX(access)
            XCTAssertEqual(converted, .blocked)
            XCTAssertTrue(access.selectionWrites.isEmpty)
            let editor = ClipboardEditor(text: "// ghbdtn ")
            editor.documentContext = context
            let result = await editor.converter().perform(automatic)
            XCTAssertEqual(result, .blocked)
            XCTAssertEqual(editor.captures, 0)
        }
    }

    func testManualConversionAndUndoDoNotReadCodePolicy() async {
        let access = FakeAXTextAccess(text: "let ghbdtn ")
        access.documentContext = source(access.value)
        access.onContextRead = { XCTFail("Ручной путь не должен читать контекст кода") }
        let manual = ConversionRequest(expectedWord: "ghbdtn", trailingText: " ", sourceLayout: .english)
        let converted = await AXTextConverter(access: access).perform(manual)
        XCTAssertEqual(converted, success)
        let undo = ConversionRequest(
            expectedWord: "привет", trailingText: " ", replacement: "ghbdtn", useSelection: false
        )
        let undone = await AXTextConverter(access: access).perform(undo)
        XCTAssertEqual(undone, .success(.init(original: "привет", converted: "ghbdtn", trailingText: " ")))

        let editor = ClipboardEditor(text: "let ghbdtn ")
        editor.documentContext = .unknown
        editor.onContextRead = { XCTFail("Ручной clipboard не должен читать контекст кода") }
        let pasted = await editor.converter().perform(manual)
        XCTAssertEqual(pasted, success)
        let restored = await editor.converter().perform(undo)
        XCTAssertEqual(restored, undone)
    }

    func testAXDocumentChangeDuringSelectionNeverWritesAnotherDocument() async {
        let access = FakeAXTextAccess(text: "// ghbdtn ")
        access.documentContext = source(access.value)
        access.onWait = { access.documentContext = self.source(access.value, document: "file:///other.swift") }
        let result = await performAX(access)
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(access.textWrites, 0)
        XCTAssertEqual(access.selectionWrites.count, 1)
    }

    func testClipboardDocumentChangeBeforeSelectionPreservesForeignDocument() async {
        let editor = ClipboardEditor(text: "// ghbdtn ")
        editor.documentContext = source(editor.text)
        editor.onWrite = { editor.documentContext = self.source(editor.text, document: "file:///other.swift") }
        let result = await editor.converter().perform(automatic)
        XCTAssertEqual(result, .blocked)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertEqual(editor.text, "// ghbdtn ")
        XCTAssertEqual(editor.restores, 1)
    }

    func testContextReadCannotAuthorizeStaleInput() async {
        let editor = ClipboardEditor(text: "// ghbdtn ")
        editor.documentContext = source(editor.text)
        editor.onContextRead = { editor.requestValid = false }
        let request = ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", sourceLayout: .english, useSelection: false,
            isValid: { editor.requestValid }
        )
        let result = await editor.converter().perform(request)
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.captures, 0)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
    }

    func testProseDocumentCannotBecomeSourceWhileSelectionSettles() async {
        let access = FakeAXTextAccess(text: "ghbdtn ")
        access.documentContext = .documentProse(document: "file:///test.txt")
        access.onWait = { access.documentContext = self.source(access.value) }
        let result = await performAX(access)
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(access.textWrites, 0)

        let editor = ClipboardEditor(text: "ghbdtn ")
        editor.documentContext = .documentProse(document: "file:///test.txt")
        editor.onWrite = { editor.documentContext = self.source(editor.text) }
        let pasted = await editor.converter().perform(automatic)
        XCTAssertEqual(pasted, .blocked)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertEqual(editor.restores, 1)
    }

    func testSameTextInAnotherDocumentDuringSnapshotDoesNotAcquirePermission() async {
        let access = FakeAXTextAccess(text: "// ghbdtn ")
        access.documentContext = source(access.value)
        access.onTextRead = { access.documentContext = self.source(access.value, document: "file:///other.swift") }
        let result = await performAX(access)
        XCTAssertEqual(result, .blocked)
        XCTAssertTrue(access.selectionWrites.isEmpty)
        XCTAssertEqual(access.textWrites, 0)

        let editor = ClipboardEditor(text: "// ghbdtn ")
        editor.documentContext = source(editor.text)
        editor.onReadState = { _ in
            editor.documentContext = self.source(editor.text, document: "file:///other.swift")
        }
        let pasted = await editor.converter().perform(automatic)
        XCTAssertEqual(pasted, .blocked)
        XCTAssertEqual(editor.captures, 0)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
    }

    private var automatic: ConversionRequest {
        ConversionRequest(expectedWord: "ghbdtn", trailingText: " ", sourceLayout: .english, useSelection: false)
    }

    private var success: ConversionResult {
        .success(.init(original: "ghbdtn", converted: "привет", trailingText: " "))
    }

    private func performAX(_ access: FakeAXTextAccess) async -> ConversionResult {
        await AXTextConverter(access: access).perform(automatic)
    }

    private func source(_ text: String, document: String = "file:///test.swift") -> AutomaticTextContext {
        .source(language: .swift, document: document, characterCount: text.utf16.count)
    }
}
