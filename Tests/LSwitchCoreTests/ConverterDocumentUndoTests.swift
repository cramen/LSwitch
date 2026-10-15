import Foundation
@testable import LSwitchCore
import XCTest

final class ConverterDocumentUndoTests: XCTestCase {
    @MainActor
    func testDocumentReuseWithIdenticalTextRejectsUndoForBothEnginesAndTriggers() async {
        for clipboard in [false, true] {
            for automatic in [false, true] {
                let editor = DocumentUndoEditor(clipboard: clipboard)
                let converted = await editor.fixture.converter.trigger(
                    expectedWord: "ghbdtn", trailingText: " ", allowUndo: !automatic
                )
                XCTAssertEqual(converted, .converted(original: "ghbdtn", converted: "привет"))
                editor.setDocument("file:///other.swift")
                let undone = await editor.fixture.converter.trigger()
                XCTAssertEqual(undone, .blockedBySafety)
                XCTAssertEqual(editor.text, "// привет ")
                XCTAssertEqual(editor.fixture.axEngine.requests.count, 1)
                XCTAssertNil(editor.fixture.undoStore.pendingUndo())
                XCTAssertEqual(editor.fixture.switchedTo, [.russian])
            }
        }
    }

    @MainActor
    func testSameDocumentStillRestoresExactTextInBothEngines() async {
        for clipboard in [false, true] {
            let editor = DocumentUndoEditor(clipboard: clipboard)
            _ = await editor.fixture.converter.trigger(expectedWord: "ghbdtn", trailingText: " ", allowUndo: false)
            let undone = await editor.fixture.converter.trigger()
            XCTAssertEqual(undone, .undone)
            XCTAssertEqual(editor.text, "// ghbdtn ")
            XCTAssertEqual(editor.fixture.axEngine.requests.count, 2)
        }
    }

    @MainActor
    func testDocumentWithoutIdentityRetainsPreviousManualUndoBoundary() async {
        let editor = DocumentUndoEditor(clipboard: false)
        editor.access.documentContext = .prose
        _ = await editor.fixture.converter.trigger(expectedWord: "ghbdtn", trailingText: " ")
        editor.access.documentContext = .unknown
        let undone = await editor.fixture.converter.trigger()
        XCTAssertEqual(undone, .undone)
        XCTAssertEqual(editor.text, "// ghbdtn ")
    }

    @MainActor
    func testDocumentChangeDuringUndoAwaitDoesNotWriteToReusedElement() async {
        let editor = DocumentUndoEditor(clipboard: false)
        _ = await editor.fixture.converter.trigger(expectedWord: "ghbdtn", trailingText: " ")
        editor.access.onWait = { editor.setDocument("file:///other.swift") }
        let undone = await editor.fixture.converter.trigger()
        XCTAssertEqual(undone, .blockedBySafety)
        XCTAssertEqual(editor.access.textWrites, 1)
        XCTAssertEqual(editor.text, "// привет ")
        XCTAssertNil(editor.fixture.undoStore.pendingUndo())
    }

    @MainActor
    func testDocumentGuardDoesNotRevokeCleanupWhenUndoLeaseExpires() async {
        let fixture = ConverterFixture()
        fixture.axEngine.result = .success(.init(original: "ghbdtn", converted: "привет", targetIsCurrent: { true }))
        _ = await fixture.converter.trigger()
        fixture.axEngine.handler = { request in
            fixture.holdActive = false
            XCTAssertFalse(request.isValid())
            XCTAssertTrue(request.canCleanup(), "Document guard не должен зависеть от истёкшего hold")
            return .blocked
        }
        let undone = await fixture.converter.trigger()
        XCTAssertEqual(undone, .blockedBySafety)
        XCTAssertFalse(fixture.holdActive)
    }

    @MainActor
    func testPartialConversionAlsoKeepsDocumentBoundUndo() async {
        let editor = DocumentUndoEditor(clipboard: false)
        editor.fixture.switchSucceeds = false
        let converted = await editor.fixture.converter.trigger(expectedWord: "ghbdtn", trailingText: " ")
        XCTAssertEqual(converted, .partiallyConverted(original: "ghbdtn", converted: "привет", targetLayout: .russian))
        editor.setDocument("file:///other.swift")
        let undone = await editor.fixture.converter.trigger()
        XCTAssertEqual(undone, .blockedBySafety)
        XCTAssertEqual(editor.text, "// привет ")
    }
}

@MainActor
private final class DocumentUndoEditor {
    let fixture = ConverterFixture()
    let access = FakeAXTextAccess(text: "// ghbdtn ")
    let clipboardEditor = ClipboardEditor(text: "// ghbdtn ")
    let clipboard: Bool

    init(clipboard: Bool) {
        self.clipboard = clipboard
        setDocument("file:///original.swift")
        if clipboard {
            fixture.axEngine.handler = { [clipboardEditor] request in
                await clipboardEditor.converter().perform(request)
            }
        } else {
            fixture.axEngine.handler = { [access] request in await AXTextConverter(access: access).perform(request) }
        }
    }

    var text: String { clipboard ? clipboardEditor.text : access.value }

    func setDocument(_ document: String) {
        access.documentContext = .source(language: .swift, document: document, characterCount: access.value.utf16.count)
        clipboardEditor.documentContext = .source(
            language: .swift, document: document, characterCount: clipboardEditor.text.utf16.count
        )
    }
}
