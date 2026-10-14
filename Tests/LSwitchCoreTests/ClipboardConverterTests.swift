import CoreGraphics
@testable import LSwitchCore
import XCTest

final class ClipboardConverterTests: XCTestCase {
    @MainActor
    func testTrailingSpaceAndContinuedTyping() async {
        let editor = ClipboardEditor(text: "ghbdtn ")
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", sourceLayout: .english, useSelection: false
        ))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.commands, [.paste])
        editor.type("мир")
        XCTAssertEqual(editor.text, "привет мир")
        XCTAssertEqual(editor.clipboard, "clipboard before")
        XCTAssertEqual(editor.restores, 1)
    }

    @MainActor
    func testHTMLSpaceIsPreserved() async {
        let editor = ClipboardEditor(text: "ghbdtn\u{00a0}")
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", sourceLayout: .english, useSelection: false
        ))
        XCTAssertEqual(result, .success(ConversionReceipt(
            original: "ghbdtn", converted: "привет", trailingText: "\u{00a0}"
        )))
        editor.type("мир")
        XCTAssertEqual(editor.text, "привет\u{00a0}мир")
    }

    @MainActor
    func testRealSelectionTakesPriorityOverBufferedWord() async {
        let editor = ClipboardEditor(text: "ghbdtn /")
        editor.selection = 7..<8
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "/", converted: ".")))
        XCTAssertEqual(editor.commands, [.paste])
        XCTAssertEqual(editor.text, "ghbdtn .")
    }

    @MainActor
    func testRetryDoesNotExtendSelection() async {
        let editor = ClipboardEditor(text: "ghbdtn ")
        editor.initialStateUnavailable = true
        editor.copyResults = [nil, "ghbdtn "]
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", trailingText: " "))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.commands, [.selectCharacters(7), .copy, .copy, .paste])
        XCTAssertEqual(editor.text, "привет ")
    }

    @MainActor
    func testMismatchCollapsesAndPreservesUnknownClipboard() async {
        let editor = ClipboardEditor(text: "ghbdtn ")
        editor.initialStateUnavailable = true
        editor.copyResults = ["new user clipboard"]
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", trailingText: " "))
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(editor.commands, [.selectCharacters(7), .copy, .collapseSelection])
        XCTAssertEqual(editor.clipboard, "new user clipboard")
        XCTAssertEqual(editor.restores, 0)
        editor.type("next")
        XCTAssertEqual(editor.text, "ghbdtn next")
    }

    @MainActor
    func testExhaustedCopyRetriesCollapseSelection() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.initialStateUnavailable = true
        editor.copyResults = [nil, nil, nil]
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(editor.commands, [.selectCharacters(6), .copy, .copy, .copy, .collapseSelection])
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.clipboard, "clipboard before")
    }

    @MainActor
    func testSecureContextDoesNotCaptureOrSendKeys() async {
        let editor = ClipboardEditor(text: "password")
        editor.safe = false
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "password"))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.captures, 0)
        XCTAssertEqual(editor.commands, [])
    }

    @MainActor
    func testFocusChangesBeforeClipboardCapture() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.onSleep = { count in if count == 1 { editor.current = false } }
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.captures, 0)
        XCTAssertEqual(editor.commands, [])
    }

    @MainActor
    func testFocusChangesAfterCopyDoesNotPasteOrMoveNewCaret() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.initialStateUnavailable = true
        editor.afterCommand = { command in if command == .copy { editor.current = false } }
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.commands, [.selectCharacters(6), .copy])
        XCTAssertEqual(editor.text, "ghbdtn")
        XCTAssertEqual(editor.writes, 0)
    }

    @MainActor
    func testRequestInvalidationStopsPaste() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.initialStateUnavailable = true
        editor.afterCommand = { command in if command == .copy { editor.requestValid = false } }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", isValid: { editor.requestValid }
        ))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.commands, [.selectCharacters(6), .copy])
        XCTAssertEqual(editor.writes, 0)
    }

    @MainActor
    func testNewUserClipboardBeforePasteIsNotOverwritten() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.onReadState = { count in if count == 2 { editor.updateClipboard("new clipboard") } }
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.clipboard, "new clipboard")
        XCTAssertEqual(editor.restores, 0)
    }

    @MainActor
    func testNewUserClipboardAfterPasteIsNotOverwritten() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.onReadState = { count in if count == 6 { editor.updateClipboard("new clipboard") } }
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет")))
        XCTAssertEqual(editor.clipboard, "new clipboard")
        XCTAssertEqual(editor.restores, 0)
    }

    @MainActor
    func testExactUndoReplacement() async {
        let editor = ClipboardEditor(text: ".")
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: ".", replacement: "/", sourceLayout: .russian, useSelection: false
        ))
        XCTAssertEqual(result, .success(ConversionReceipt(original: ".", converted: "/")))
        XCTAssertEqual(editor.text, "/")
    }

    @MainActor
    func testPastedTextSelectionIsCollapsedBeforeSuccess() async {
        let editor = ClipboardEditor(text: "ghbdtn ")
        editor.keepPastedSelection = true
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", trailingText: " "))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.rangeWrites.last, NSRange(location: 7, length: 0))
        editor.type("мир")
        XCTAssertEqual(editor.text, "привет мир")
    }

    @MainActor
    func testRejectedPasteIsFailureAndSelectionIsCollapsed() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.rejectPaste = true
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.rangeWrites.last, NSRange(location: 6, length: 0))
        editor.type(" next")
        XCTAssertEqual(editor.text, "ghbdtn next")
    }

    @MainActor
    func testFallbackWithoutBufferSelectsOneWord() async {
        let editor = ClipboardEditor(text: "hello ghbdtn")
        editor.initialStateUnavailable = true
        let result = await editor.converter().perform(ConversionRequest())
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет")))
        XCTAssertEqual(editor.commands, [.selectWord, .copy, .paste])
        XCTAssertEqual(editor.text, "hello привет")
    }
}

extension ClipboardConverterTests {
    @MainActor
    func testCommandsCarryLatinUnicodeAndCommandTransitions() async throws {
        for (command, expected) in [(ClipboardCommand.copy, "c"), (.paste, "v")] {
            let events = try XCTUnwrap(KeyboardEmitter.events(for: command))
            XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
            XCTAssertEqual(events.first?.flags, .maskCommand)
            XCTAssertEqual(events.last?.flags, [])
            for event in events {
                XCTAssertTrue(SyntheticEventMarker.isSynthetic(event))
            }
            for event in events.filter({ $0.type == .keyDown || $0.type == .keyUp }) {
                var units = [UniChar](repeating: 0, count: 8)
                var length = 0
                event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &units)
                XCTAssertEqual(String(decoding: units.prefix(length), as: UTF16.self), expected)
                XCTAssertEqual(event.flags, .maskCommand)
            }
        }
    }

    @MainActor
    func testAllSelectionEventsAreMarkedSynthetic() async throws {
        for command in [ClipboardCommand.selectCharacters(7), .selectWord, .collapseSelection] {
            let events = try XCTUnwrap(KeyboardEmitter.events(for: command))
            XCTAssertTrue(events.allSatisfy { SyntheticEventMarker.isSynthetic($0) })
        }
        XCTAssertNil(KeyboardEmitter.events(for: .selectCharacters(0)))
    }
}

extension ClipboardConverterTests {
    @MainActor
    func testMenuCommandMatchesOnlyEnabledPlainCommandShortcut() async {
        XCTAssertTrue(MenuCommand.matches(.copy, character: "C", modifiers: 0, enabled: true))
        XCTAssertTrue(MenuCommand.matches(.paste, character: "v", modifiers: 0, enabled: true))
        XCTAssertFalse(MenuCommand.matches(.copy, character: "v", modifiers: 0, enabled: true))
        XCTAssertFalse(MenuCommand.matches(.copy, character: "c", modifiers: 0, enabled: false))
        XCTAssertFalse(MenuCommand.matches(.copy, character: nil, modifiers: 0, enabled: true))
    }

    @MainActor
    func testMenuCommandRejectsExtraOrAbsentCommandModifier() async {
        for modifiers in [1, 2, 4, 8, 15] {
            XCTAssertFalse(MenuCommand.matches(.paste, character: "v", modifiers: modifiers, enabled: true))
        }
        XCTAssertFalse(MenuCommand.matches(.paste, character: "v", modifiers: nil, enabled: true))
        XCTAssertFalse(MenuCommand.matches(.selectWord, character: "c", modifiers: 0, enabled: true))
    }
}

extension ClipboardConverterTests {
    @MainActor
    func testConfirmedPasteSkipsPostPasteDelayAndUsesUTF16Caret() async {
        let editor = ClipboardEditor(text: "🙂 ghbdtn ")
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", trailingText: " "))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.text, "🙂 привет ")
        XCTAssertEqual(editor.sleepDelays, [0.02])
        XCTAssertEqual(editor.clipboard, "clipboard before")
    }

    @MainActor
    func testUnavailableAXStateRetainsConservativePostPasteDelay() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.exposesState = false
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.sleepDelays, [0.02, 0.15])
    }

    @MainActor
    func testInputDuringPreparationCancelsBeforeSelection() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.onPrepare = { editor.requestValid = false }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", isValid: { editor.requestValid }
        ))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.preparations, 1)
        XCTAssertEqual(editor.captures, 0)
        XCTAssertEqual(editor.commands, [])
    }

    @MainActor
    func testDeferredPasteAcknowledgementUsesShortPoll() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.deferredPaste = true
        editor.onSleep = { count in
            if count == 2, let pending = editor.pendingPaste { editor.type(pending) }
        }
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет")))
        XCTAssertEqual(editor.sleepDelays, [0.02, 0.02])
    }

    @MainActor
    func testForeignClipboardImmediatelyBeforeCommandPreventsPaste() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.beforeCommand = { command in if command == .paste { editor.updateClipboard("new clipboard") } }
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [])
        XCTAssertEqual(editor.text, "ghbdtn")
        XCTAssertEqual(editor.clipboard, "new clipboard")
        XCTAssertNil(editor.selection)
    }

    @MainActor
    func testUnknownWrittenTextFailsWithoutMovingUnrecognizedCaret() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.afterCommand = { command in if command == .paste { editor.text = "другой" } }
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn"))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [.paste])
        XCTAssertEqual(editor.sleepDelays, [0.02, 0.02, 0.02, 0.02])
    }
}

extension ClipboardConverterTests {
    @MainActor
    func testAXNonbreakingSpaceSurvivesClipboardNormalization() async {
        let editor = ClipboardEditor(text: "ghbdtn\u{00a0}")
        editor.initialStateUnavailable = true
        editor.copyResults = ["ghbdtn "]
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", useSelection: true
        ))
        XCTAssertEqual(result, .success(ConversionReceipt(
            original: "ghbdtn", converted: "привет", trailingText: "\u{00a0}"
        )))
        XCTAssertEqual(editor.text, "привет\u{00a0}")
        XCTAssertEqual(editor.sleepDelays, [0.02])
    }

    @MainActor
    func testUnreliableRangeUsesMatchingSelectedTextAndClipboard() async {
        let editor = ClipboardEditor(text: "ghbdtn ")
        editor.initialStateUnavailable = true
        editor.stateOverride = ("ghbdtn ", NSRange(location: 0, length: 0))
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", useSelection: true
        ))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.text, "привет ")
        XCTAssertEqual(editor.sleepDelays, [0.02, 0.15])
    }

    @MainActor
    func testChangedActualSelectionPreventsPaste() async {
        let editor = ClipboardEditor(text: "ghbdtn")
        editor.initialStateUnavailable = true
        editor.afterCommand = { command in if command == .copy { editor.text = "другой" } }
        let result = await editor.converter().perform(ConversionRequest(expectedWord: "ghbdtn", useSelection: true))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.commands, [.selectCharacters(6), .copy])
        XCTAssertEqual(editor.text, "другой")
        XCTAssertEqual(editor.writes, 0)
        XCTAssertEqual(editor.selection, 0..<6)
    }
}
