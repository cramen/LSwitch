import CoreGraphics
@testable import LSwitchCore
import XCTest

extension ClipboardConverterTests {
    @MainActor
    func testScriptSelectionChangeBetweenCommandAndVDoesNotPasteOrOverwriteForeignRange() async {
        let editor = ClipboardEditor(text: "prefix ghbdtn ")
        var posted: [CGEvent] = []
        editor.commandTransport = ClipboardCommandTransport(
            currentTarget: { .init(processID: 100, bundleID: "com.google.Chrome") },
            prepareMenu: { _, _ in XCTFail("Chrome не должен искать меню") },
            invokeMenu: { _, _, _ in XCTFail("Chrome не должен вызывать меню"); return .failed },
            commitMenu: { _, _, _, _ in XCTFail("Chrome не должен вставлять через меню"); return .failed },
            sendKeyboard: { command, targetPID, valid, beforeKeyDown in
                await KeyboardEmitter.send(
                    command, targetPID: targetPID, isValid: valid, beforeKeyDown: beforeKeyDown,
                    delivery: .init(post: { event, _ in posted.append(event) }, pause: { editor.selection = 0..<3 })
                )
            }
        )
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", sourceLayout: .english, useSelection: false
        ))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(posted.map(\.type), [.flagsChanged, .flagsChanged])
        XCTAssertEqual(posted.map(\.flags), [.maskCommand, []])
        XCTAssertEqual(editor.rangeWrites, [NSRange(location: 7, length: 7)])
        XCTAssertEqual(editor.selection, 0..<3)
        XCTAssertEqual(editor.text, "prefix ghbdtn ")
        XCTAssertEqual(editor.clipboard, "clipboard before")
    }
}
