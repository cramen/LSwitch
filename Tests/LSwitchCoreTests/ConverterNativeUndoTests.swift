import Foundation
@testable import LSwitchCore
import XCTest

final class ConverterNativeUndoTests: XCTestCase {
    @MainActor
    func testUnicodeMiddleSelectionRefusesWithoutPreparingPacketOrSavingUndo() async {
        let editor = UnicodeTestEditor("prefix ghbdtn suffix")
        editor.selection = NSRange(location: 7, length: 6)
        let fixture = unicodeFixture(editor)
        var samples: [ConversionDiagnostics.Sample] = []
        let outcome = await fixture.converter.trigger(diagnostics: trace { samples.append($0) })
        XCTAssertEqual(outcome, .blockedBySafety)
        XCTAssertEqual(samples.last?.reason, .keyboardUndoUnavailable)
        XCTAssertEqual(editor.text, "prefix ghbdtn suffix")
        XCTAssertEqual(editor.selection, NSRange(location: 7, length: 6))
        XCTAssertEqual(editor.prepares, 0)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertTrue(editor.commands.isEmpty)
        assertRefusedWithoutFallback(fixture)
        XCTAssertTrue(fixture.clipboardEngine.requests.isEmpty)
    }

    @MainActor
    func testUnicodeSelectedEOFConvertsAndExactlyUndoesInBothDirections() async {
        let fixtures: [((String, String), Layout)] = [
            (("ghbdtn", "привет"), .english), (("цщкдв", "world"), .russian)
        ]
        for ((original, converted), layout) in fixtures {
            let prefix = "😀 e\u{301} "
            let editor = UnicodeTestEditor(prefix + original)
            editor.selection = NSRange(location: prefix.utf16.count, length: original.utf16.count)
            editor.source = source(layout)
            let fixture = unicodeFixture(editor)
            fixture.layout = layout
            let result = await fixture.converter.trigger()
            XCTAssertEqual(result, .converted(original: original, converted: converted))
            XCTAssertTrue(editor.commands.isEmpty)
            XCTAssertEqual(editor.text, prefix + converted)
            editor.source = source(layout.opposite)
            let undone = await fixture.converter.trigger()
            XCTAssertEqual(undone, .undone)
            XCTAssertTrue(editor.text.utf16.elementsEqual((prefix + original).utf16))
            XCTAssertEqual(editor.selection, NSRange(location: editor.text.utf16.count, length: 0))
            XCTAssertEqual(editor.commands, [.select(converted.count)])
            XCTAssertEqual(editor.downCount, 2)
            XCTAssertEqual(editor.upCount, 2)
            XCTAssertEqual(fixture.switchedTo, [layout.opposite, layout])
            XCTAssertNil(fixture.undoStore.pendingUndo())
            XCTAssertFalse(fixture.holdActive)
            XCTAssertTrue(fixture.axEngine.requests.isEmpty)
            XCTAssertTrue(fixture.clipboardEngine.requests.isEmpty)
        }
    }

    @MainActor
    func testNativeClipboardMiddleSelectionRefusesBeforeCaptureAndPreservesUserSelection() async {
        let editor = ClipboardEditor(text: "prefix ghbdtn suffix")
        editor.selection = 7..<13
        let fixture = clipboardFixture(editor)
        var samples: [ConversionDiagnostics.Sample] = []
        let outcome = await fixture.converter.trigger(diagnostics: trace { samples.append($0) })
        XCTAssertEqual(outcome, .blockedBySafety)
        XCTAssertEqual(samples.last?.reason, .keyboardUndoUnavailable)
        XCTAssertEqual(editor.text, "prefix ghbdtn suffix")
        XCTAssertEqual(editor.selection, 7..<13)
        assertClipboardUntouched(editor)
        assertRefusedWithoutFallback(fixture)
        XCTAssertTrue(fixture.unicodeEngine.requests.isEmpty)
    }

    @MainActor
    func testNativeClipboardSelectedEOFConvertsAndExactlyUndoes() async {
        let prefix = "😀 e\u{301} "
        let editor = ClipboardEditor(text: prefix + "ghbdtn")
        editor.selection = prefix.count..<editor.text.count
        let fixture = clipboardFixture(editor)
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(editor.commands, [.paste])
        let undone = await fixture.converter.trigger()
        XCTAssertEqual(undone, .undone)
        XCTAssertTrue(editor.text.utf16.elementsEqual((prefix + "ghbdtn").utf16))
        XCTAssertEqual(editor.cursor, editor.text.count)
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.commands, [.paste, .selectCharacters(6), .paste])
        XCTAssertEqual(editor.captures, 2)
        XCTAssertEqual(editor.restores, 2)
        XCTAssertEqual(editor.clipboard, "clipboard before")
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertTrue(fixture.axEngine.requests.isEmpty)
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertFalse(fixture.holdActive)
    }

    @MainActor
    func testNativeClipboardLongSelectionRefusesBeforeCaptureEvenAtEOF() async {
        let original = String(repeating: "a", count: KeyboardSelectionPlan.maximumCharacters + 1)
        let editor = ClipboardEditor(text: original)
        editor.selection = 0..<original.count
        let fixture = clipboardFixture(editor)
        var samples: [ConversionDiagnostics.Sample] = []
        let result = await fixture.converter.trigger(diagnostics: trace { samples.append($0) })
        XCTAssertEqual(result, .blockedBySafety)
        XCTAssertEqual(samples.last?.reason, .keyboardUndoUnavailable)
        XCTAssertEqual(editor.text, original)
        XCTAssertEqual(editor.selection, 0..<original.count)
        assertClipboardUntouched(editor)
        assertRefusedWithoutFallback(fixture)
    }

    @MainActor
    func testNativeClipboardCombiningInverseBoundaryRefusesBeforeCapture() async {
        let editor = ClipboardEditor(text: "x a")
        editor.selection = 2..<3
        editor.selectionMethod = .keyboard
        let result = await editor.converter().perform(ConversionRequest(replacement: "\u{301}"))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.text, "x a")
        XCTAssertEqual(editor.selection, 2..<3)
        assertClipboardUntouched(editor)
    }

    @MainActor
    func testNativeClipboardMissingSnapshotCannotBypassInverseCheckThroughLegacyCopy() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.selection = 0..<6
        editor.exposesState = false
        let fixture = clipboardFixture(editor)
        var samples: [ConversionDiagnostics.Sample] = []
        let result = await fixture.converter.trigger(diagnostics: trace { samples.append($0) })
        XCTAssertEqual(result, .blockedBySafety)
        XCTAssertEqual(samples.last?.reason, .keyboardUndoUnavailable)
        XCTAssertEqual(editor.text, "ghbdtn")
        XCTAssertEqual(editor.selection, 0..<6)
        assertClipboardUntouched(editor)
        assertRefusedWithoutFallback(fixture)
    }

    #if DEBUG
    @MainActor
    func testExplicitForcedCopyAcceptanceStillUsesLegacyTransport() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.selection = 0..<6
        var configuration = ClipboardConverter.Configuration()
        configuration.forceCopyForAcceptance = true
        let fixture = clipboardFixture(editor, configuration: configuration)
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(editor.commands, [.copy, .paste])
        XCTAssertEqual(editor.captures, 1)
        XCTAssertEqual(editor.restores, 1)
        XCTAssertEqual(editor.text, "привет")
        XCTAssertEqual(editor.clipboard, "clipboard before")
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertTrue(fixture.axEngine.requests.isEmpty)
    }
    #endif

    @MainActor
    private func unicodeFixture(_ editor: UnicodeTestEditor) -> ConverterFixture {
        let fixture = ConverterFixture()
        fixture.unicodePreferred = true
        let engine = editor.converter()
        // Stub только записывает запросы; результат формирует настоящий движок и его транзакция.
        fixture.unicodeEngine.handler = { await engine.perform($0) }
        return fixture
    }

    @MainActor
    private func clipboardFixture(
        _ editor: ClipboardEditor, configuration: ClipboardConverter.Configuration = .init()
    ) -> ConverterFixture {
        let fixture = ConverterFixture()
        fixture.clipboardPreferred = true
        editor.selectionMethod = .keyboard
        let engine = editor.converter(configuration: configuration)
        fixture.clipboardEngine.handler = { await engine.perform($0) }
        return fixture
    }

    @MainActor
    private func assertRefusedWithoutFallback(_ fixture: ConverterFixture) {
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertTrue(fixture.axEngine.requests.isEmpty)
        XCTAssertTrue(fixture.switchedTo.isEmpty)
        XCTAssertEqual(fixture.convertedNotifications, 0)
        XCTAssertEqual(fixture.actions, ["hold", "release"])
        XCTAssertFalse(fixture.holdActive)
    }

    @MainActor
    private func assertClipboardUntouched(_ editor: ClipboardEditor) {
        XCTAssertEqual(editor.captures, 0)
        XCTAssertEqual(editor.writes, 0)
        XCTAssertEqual(editor.restores, 0)
        XCTAssertEqual(editor.count, 0)
        XCTAssertEqual(editor.clipboard, "clipboard before")
        XCTAssertTrue(editor.commands.isEmpty)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
    }

    @MainActor
    private func trace(_ emit: @escaping (ConversionDiagnostics.Sample) -> Void) -> ConversionDiagnostics {
        ConversionDiagnostics(
            bundleID: "test.app", triggerTimestamp: nil, attempt: 1, automatic: false, now: { 20 }, emit: emit
        )
    }

    private func source(_ layout: Layout) -> UnicodeInputSource? {
        UnicodeInputSource(identifier: layout == .english ? "com.apple.keylayout.ABC" : "com.apple.keylayout.Russian",
                           isKeyboardLayout: true)
    }
}
