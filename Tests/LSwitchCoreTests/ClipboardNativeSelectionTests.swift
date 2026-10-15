import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class ClipboardNativeSelectionTests: XCTestCase {
    func testVerifiedNativeSelectionConvertsBothDirectionsWithoutCopyOrAXSetter() async {
        let fixtures: [(String, String, Layout)] = [("ghbdtn", "привет", .english), ("цщкдв", "world", .russian)]
        for (original, converted, layout) in fixtures {
            let editor = nativeEditor("🙂 " + original + " ")
            editor.rangeSettable = false
            let result = await editor.converter().perform(request(word: original, layout: layout))
            XCTAssertEqual(result, .success(.init(original: original, converted: converted, trailingText: " ")))
            XCTAssertEqual(editor.commands, [.selectCharacters(original.count + 1), .paste])
            XCTAssertTrue(editor.rangeWrites.isEmpty)
            XCTAssertEqual(editor.text, "🙂 " + converted + " ")
            XCTAssertNil(editor.selection)
            XCTAssertEqual(editor.clipboard, "clipboard before")
        }
    }

    func testPartialDeliveryNeverPastesAndNativeCleanupRestoresCaret() async {
        let editor = nativeEditor("prefix ghbdtn ")
        editor.afterCommand = { command in
            if case .selectCharacters = command { editor.selection = 12..<14 }
        }
        let result = await editor.converter().perform(request())
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [.selectCharacters(7), .collapseSelection])
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.cursor, 14)
        editor.type("next")
        XCTAssertEqual(editor.text, "prefix ghbdtn next")
        XCTAssertEqual(editor.clipboard, "clipboard before")
    }

    func testProgressThroughOwnedSuffixesMustSettleAtFullRange() async {
        let editor = nativeEditor("prefix ghbdtn ")
        editor.afterCommand = { command in
            if case .selectCharacters = command { editor.selection = 13..<14 }
        }
        editor.onSleep = { count in
            if count == 1 { editor.selection = 10..<14 }
            if count == 2 { editor.selection = 7..<14 }
        }
        let result = await editor.converter().perform(request())
        XCTAssertEqual(result, .success(.init(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.commands, [.selectCharacters(7), .paste])
        XCTAssertTrue(editor.rangeWrites.isEmpty)
    }

    func testIgnoredSelectionStillQueuesIdempotentCancellationAtDocumentEnd() async {
        let editor = nativeEditor("prefix ghbdtn ")
        editor.afterCommand = { command in
            if case .selectCharacters = command { editor.selection = nil }
        }
        let result = await editor.converter().perform(request())
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [.selectCharacters(7), .collapseSelection])
        XCTAssertEqual(editor.cursor, 14)
        XCTAssertNil(editor.selection)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
    }

    func testBatchDeliveredOnSeventhYieldIsCancelledBeforeNextInput() async {
        let editor = nativeEditor("prefix ghbdtn ")
        var queued: [ClipboardCommand] = []
        editor.afterCommand = { command in
            if case .selectCharacters = command {
                queued.append(command)
                editor.selection = nil
            }
            if command == .collapseSelection { queued.append(command) }
        }
        editor.onSleep = { count in
            guard count == 7 else { return }
            for command in queued {
                switch command {
                case .selectCharacters(let length):
                    editor.selection = (editor.cursor - length)..<editor.cursor
                case .collapseSelection:
                    editor.cursor = editor.selection?.upperBound ?? editor.cursor
                    editor.selection = nil
                default: XCTFail("В очереди отмены не должно быть Copy/Paste")
                }
            }
            queued.removeAll()
        }
        let result = await editor.converter().perform(request())
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(queued, [.selectCharacters(7), .collapseSelection])
        XCTAssertEqual(editor.sleeps, 6)
        // Приложение ещё не исполнило ни batch, ни ordered cancel. Их порядок
        // уже определён до выпуска следующего ввода; cached readback не является ACK.
        editor.onSleep(7)
        XCTAssertNil(editor.selection)
        editor.type("next")
        XCTAssertEqual(editor.text, "prefix ghbdtn next")
        XCTAssertEqual(editor.clipboard, "clipboard before")
        XCTAssertTrue(editor.rangeWrites.isEmpty)
    }

    func testForeignRangeOrFocusChangeStopsWithoutCleanupInAnotherContext() async {
        for changesFocus in [false, true] {
            let editor = nativeEditor("prefix ghbdtn ")
            editor.afterCommand = { command in
                if case .selectCharacters = command {
                    if changesFocus { editor.current = false }
                    else { editor.selection = 0..<3 }
                }
            }
            let result = await editor.converter().perform(request())
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(editor.commands, [.selectCharacters(7)])
            XCTAssertTrue(editor.rangeWrites.isEmpty)
            XCTAssertEqual(editor.text, "prefix ghbdtn ")
            if !changesFocus { XCTAssertEqual(editor.selection, 0..<3) }
        }
    }

    func testAmbiguousPasteIsNotRetriedAndOwnRangeIsCollapsedNatively() async {
        let editor = nativeEditor("prefix ghbdtn ")
        editor.rejectPaste = true
        let result = await editor.converter().perform(request())
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [.selectCharacters(7), .paste, .collapseSelection])
        XCTAssertEqual(editor.text, "prefix ghbdtn ")
        XCTAssertEqual(editor.clipboard, "clipboard before")
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertNil(editor.selection)
    }

    func testSelectedReplacementIsCollapsedNativelyAfterConfirmedPaste() async {
        let editor = nativeEditor("ghbdtn ")
        editor.keepPastedSelection = true
        let result = await editor.converter().perform(request())
        XCTAssertEqual(result, .success(.init(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.commands, [.selectCharacters(7), .paste, .collapseSelection])
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.cursor, 7)
    }

    func testExistingUserSelectionIsNeverExpandedOrRecreated() async {
        let editor = nativeEditor("prefix ghbdtn suffix")
        editor.selection = 7..<13
        let result = await editor.converter().perform(ConversionRequest(sourceLayout: .english))
        XCTAssertEqual(result, .success(.init(original: "ghbdtn", converted: "привет")))
        XCTAssertEqual(editor.commands, [.paste])
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertEqual(editor.text, "prefix привет suffix")
    }

    func testForeignClipboardAfterSelectionIsPreservedAndNeverPasted() async {
        let editor = nativeEditor("ghbdtn ")
        editor.afterCommand = { command in
            if case .selectCharacters = command { editor.updateClipboard("new user copy") }
        }
        let result = await editor.converter().perform(request())
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [.selectCharacters(7), .collapseSelection])
        XCTAssertEqual(editor.clipboard, "new user copy")
        XCTAssertEqual(editor.restores, 0)
        XCTAssertEqual(editor.text, "ghbdtn ")
    }

    func testUnprovenBidirectionalRangeRefusesBeforeClipboardOrSelection() async {
        let editor = nativeEditor("שלום ghbdtn ")
        let result = await editor.converter().perform(request())
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.captures, 0)
        XCTAssertEqual(editor.writes, 0)
        XCTAssertTrue(editor.commands.isEmpty)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
    }

    func testMidDocumentCaretRefusesBeforeClipboardAndSelection() async {
        let editor = nativeEditor("ghbdtn suffix")
        editor.cursor = 7
        let result = await editor.converter().perform(request())
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.captures, 0)
        XCTAssertEqual(editor.writes, 0)
        XCTAssertTrue(editor.commands.isEmpty)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertEqual(editor.cursor, 7)
    }

    func testForeignRangeAfterCommandDownPreventsVDownInNativeSelectionPath() async {
        let editor = nativeEditor("prefix ghbdtn ")
        var commands: [ClipboardCommand] = []
        var selectedCharacters = 0
        var pasteEvents: [CGEventType] = []
        editor.commandTransport = ClipboardCommandTransport(
            currentTarget: { .init(processID: 100, bundleID: "com.google.Chrome") },
            prepareMenu: { _, _ in XCTFail("Chrome не должен готовить AX меню") },
            invokeMenu: { _, _, _ in XCTFail("Chrome не должен искать AX fallback"); return .failed },
            commitMenu: { _, _, _, _ in XCTFail("Chrome не должен вставлять через AX"); return .failed },
            sendKeyboard: { command, targetPID, valid, beforeKeyDown in
                commands.append(command)
                return await KeyboardEmitter.send(
                    command, targetPID: targetPID, isValid: valid, beforeKeyDown: beforeKeyDown,
                    delivery: .init(post: { event, _ in
                        XCTAssertTrue(SyntheticEventMarker.isSynthetic(event))
                        if case .selectCharacters = command, event.type == .keyDown {
                            selectedCharacters += 1
                            editor.selection = (editor.cursor - selectedCharacters)..<editor.cursor
                        }
                        if command == .paste { pasteEvents.append(event.type) }
                    }, pause: {
                        if command == .paste { editor.selection = 0..<3 }
                    })
                )
            }
        )
        let result = await editor.converter().perform(request())
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(commands, [.selectCharacters(7), .paste])
        XCTAssertEqual(pasteEvents, [.flagsChanged, .flagsChanged])
        XCTAssertEqual(editor.selection, 0..<3)
        XCTAssertEqual(editor.text, "prefix ghbdtn ")
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertEqual(editor.clipboard, "clipboard before")
    }

    private func nativeEditor(_ text: String) -> ClipboardEditor {
        let editor = ClipboardEditor(text: text)
        editor.selectionMethod = .keyboard
        return editor
    }

    private func request(word: String = "ghbdtn", layout: Layout = .english) -> ConversionRequest {
        ConversionRequest(expectedWord: word, trailingText: " ", sourceLayout: layout, useSelection: false)
    }
}
