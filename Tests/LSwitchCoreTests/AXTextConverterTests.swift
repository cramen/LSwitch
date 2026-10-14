import ApplicationServices
@testable import LSwitchCore
import XCTest

final class AXTextConverterTests: XCTestCase {
    @MainActor
    func testInputHoldRefusalDoesNotCreateSelection() async {
        let access = FakeAXTextAccess(text: "ghbdtn ")
        let result = AXTextConverter(access: access).perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", useSelection: false, beginMutation: { false }
        ))
        XCTAssertEqual(result, .blocked)
        XCTAssertTrue(access.selectionWrites.isEmpty)
        XCTAssertEqual(access.textWrites, 0)
        XCTAssertEqual(access.value, "ghbdtn ")
    }

    @MainActor
    func testExpiredHoldRestoresOwnSelectionBeforeInputRelease() async {
        let access = FakeAXTextAccess(text: "ghbdtn ")
        let result = AXTextConverter(access: access).perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", useSelection: false,
            canCleanup: { true }, isValid: { access.selectionWrites.isEmpty }
        ))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(access.textWrites, 0)
        XCTAssertEqual(access.currentSelection, NSRange(location: 7, length: 0))
        access.typeText("vbh")
        XCTAssertEqual(access.value, "ghbdtn vbh")
    }

    @MainActor
    func testExpiredHoldAfterWriteCollapsesRecognizedReplacement() async {
        let access = FakeAXTextAccess(text: "ghbdtn ")
        let result = AXTextConverter(access: access).perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", sourceLayout: .english, useSelection: false,
            canCleanup: { true }, isValid: { access.textWrites == 0 }
        ))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(access.currentSelection, NSRange(location: 7, length: 0))
        access.typeText("мир")
        XCTAssertEqual(access.value, "привет мир")
    }

    @MainActor
    func testEmojiPrefixAndTrailingSpacePreserveCaretForContinuedTyping() async {
        let access = FakeAXTextAccess(text: "😀 ghbdtn ")
        let result = AXTextConverter(access: access).perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", sourceLayout: .english, useSelection: false
        ))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(access.value, "😀 привет ")
        XCTAssertEqual(access.currentSelection, NSRange(location: 10, length: 0))
        access.typeText("мир")
        XCTAssertEqual(access.value, "😀 привет мир")
    }

    @MainActor
    func testHTMLNonbreakingSpaceIsPreservedExactly() async {
        let access = FakeAXTextAccess(text: "руддщ\u{00a0}")
        let result = AXTextConverter(access: access).perform(ConversionRequest(
            expectedWord: "руддщ", trailingText: " ", sourceLayout: .russian, useSelection: false
        ))
        XCTAssertEqual(result, .success(ConversionReceipt(
            original: "руддщ", converted: "hello", trailingText: "\u{00a0}"
        )))
        XCTAssertEqual(access.value, "hello\u{00a0}")
        XCTAssertEqual(access.currentSelection, NSRange(location: 6, length: 0))
    }

    @MainActor
    func testSelectionOverridesBufferedWordAndUndoUsesExactOriginal() async {
        let access = FakeAXTextAccess(text: "prefix / suffix", selection: NSRange(location: 7, length: 1))
        let converter = AXTextConverter(access: access)
        let result = converter.perform(ConversionRequest(expectedWord: "prefix", sourceLayout: .english))
        XCTAssertEqual(result, .success(ConversionReceipt(original: "/", converted: ".")))
        XCTAssertEqual(access.value, "prefix . suffix")
        XCTAssertEqual(access.currentSelection, NSRange(location: 8, length: 0))
        let undone = converter.perform(ConversionRequest(
            expectedWord: ".", replacement: "/", sourceLayout: .russian, useSelection: false
        ))
        XCTAssertEqual(undone, .success(ConversionReceipt(original: ".", converted: "/")))
        XCTAssertEqual(access.value, "prefix / suffix")
        XCTAssertEqual(access.currentSelection, NSRange(location: 8, length: 0))
    }

    @MainActor
    func testManualLastWordKeepsTrailingDelimiters() async {
        let access = FakeAXTextAccess(text: "ghbdtn,  ")
        let result = AXTextConverter(access: access).perform(ConversionRequest(sourceLayout: .english))
        XCTAssertEqual(result, .success(ConversionReceipt(
            original: "ghbdtn", converted: "привет", trailingText: ",  "
        )))
        XCTAssertEqual(access.value, "привет,  ")
        XCTAssertEqual(access.currentSelection, NSRange(location: 9, length: 0))
    }

    @MainActor
    func testAutomaticRequestDoesNotUseUnrelatedSelection() async {
        let access = FakeAXTextAccess(text: "ghbdtn hello", selection: NSRange(location: 7, length: 5))
        let result = AXTextConverter(access: access).perform(ConversionRequest(
            expectedWord: "ghbdtn", useSelection: false
        ))
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(access.value, "ghbdtn hello")
        XCTAssertEqual(access.currentSelection, NSRange(location: 7, length: 5))
        XCTAssertTrue(access.selectionWrites.isEmpty)
        XCTAssertEqual(access.textWrites, 0)
    }

    @MainActor
    func testSelectionFailureRestoresOriginalCaretBeforeFallback() async {
        let access = FakeAXTextAccess(text: "ghbdtn ")
        access.failFirstSelection = true
        let result = AXTextConverter(access: access).perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", useSelection: false
        ))
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(access.value, "ghbdtn ")
        XCTAssertEqual(access.currentSelection, NSRange(location: 7, length: 0))
        XCTAssertEqual(access.selectionWrites, [NSRange(location: 0, length: 7), NSRange(location: 7, length: 0)])
        XCTAssertEqual(access.textWrites, 0)
    }

    @MainActor
    func testWriteFailureRestoresSelectionAndForbidsFallback() async {
        let access = FakeAXTextAccess(text: "ghbdtn ")
        access.failTextWrite = true
        let result = AXTextConverter(access: access).perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", useSelection: false
        ))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(access.value, "ghbdtn ")
        XCTAssertEqual(access.currentSelection, NSRange(location: 7, length: 0))
        XCTAssertEqual(access.textWrites, 1)
    }

    @MainActor
    func testSuccessfulNoOpRestoresCaretAndAllowsSafeFallback() async {
        let access = FakeAXTextAccess(text: "руддщ ")
        access.ignoreTextWrite = true
        let result = AXTextConverter(access: access).perform(ConversionRequest(
            expectedWord: "руддщ", trailingText: " ", sourceLayout: .russian, useSelection: false
        ))
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(access.value, "руддщ ")
        XCTAssertEqual(access.currentSelection, NSRange(location: 6, length: 0))
        XCTAssertEqual(access.textWrites, 1)
        access.typeText("world")
        XCTAssertEqual(access.value, "руддщ world")
    }

    @MainActor
    func testFalseSuccessWithInsertionForbidsFallback() async {
        let access = FakeAXTextAccess(text: "ghbdtn")
        access.insertInsteadOfReplacing = true
        let result = AXTextConverter(access: access).perform(ConversionRequest(sourceLayout: .english))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(access.value, "ghbdtnпривет")
        XCTAssertEqual(access.currentSelection, NSRange(location: 12, length: 0))
        XCTAssertEqual(access.textWrites, 1)
    }

    @MainActor
    func testUnsupportedAXWriteDoesNotChangeSelectionOrText() async {
        let access = FakeAXTextAccess(text: "ghbdtn")
        access.textIsSettable = false
        XCTAssertEqual(AXTextConverter(access: access).perform(ConversionRequest()), .unavailable)
        XCTAssertTrue(access.selectionWrites.isEmpty)
        XCTAssertEqual(access.textWrites, 0)
    }

    @MainActor
    func testSecureFieldIsBlockedWithoutReadingTextOrWriting() async {
        let access = FakeAXTextAccess(text: "ghbdtn")
        access.protected = true
        XCTAssertEqual(AXTextConverter(access: access).perform(ConversionRequest()), .blocked)
        XCTAssertEqual(access.textReads, 0)
        XCTAssertEqual(access.selectionReads, 0)
        XCTAssertTrue(access.selectionWrites.isEmpty)
        XCTAssertEqual(access.textWrites, 0)
    }

    @MainActor
    func testInvalidRequestIsBlockedBeforeSystemAccess() async {
        let access = FakeAXTextAccess(text: "ghbdtn")
        let request = ConversionRequest(isValid: { false })
        XCTAssertEqual(AXTextConverter(access: access).perform(request), .blocked)
        XCTAssertEqual(access.focusReads, 0)
        XCTAssertEqual(access.textReads, 0)
        XCTAssertEqual(access.textWrites, 0)
    }

    @MainActor
    func testFocusChangedAfterSelectionDoesNotWriteToEitherField() async {
        let access = FakeAXTextAccess(text: "ghbdtn")
        access.changeFocusAfterSelection = true
        XCTAssertEqual(AXTextConverter(access: access).perform(ConversionRequest()), .blocked)
        XCTAssertEqual(access.value, "ghbdtn")
        XCTAssertEqual(access.selectionWrites.count, 1)
        XCTAssertEqual(access.textWrites, 0)
    }

    @MainActor
    func testCollapsedCaretIsVerifiedEvenWhenTextWriteLeavesSelection() async {
        let access = FakeAXTextAccess(text: "ghbdtn ")
        access.failFinalCaret = true
        let request = ConversionRequest(expectedWord: "ghbdtn", trailingText: " ", useSelection: false)
        XCTAssertEqual(AXTextConverter(access: access).perform(request), .failed)
        XCTAssertEqual(access.value, "привет ")
        XCTAssertEqual(access.currentSelection, NSRange(location: 0, length: 7))
        XCTAssertEqual(access.textWrites, 1)
    }
}

@MainActor
private final class FakeAXTextAccess: AXTextAccess {
    let element = AXUIElementCreateApplication(100)
    let otherElement = AXUIElementCreateApplication(101)
    var value: String
    var currentSelection: NSRange
    var protected = false
    var textIsSettable = true
    var failFirstSelection = false
    var failTextWrite = false
    var ignoreTextWrite = false
    var failFinalCaret = false
    var insertInsteadOfReplacing = false
    var changeFocusAfterSelection = false
    var selectionWrites: [NSRange] = []
    var textWrites = 0
    var textReads = 0
    var selectionReads = 0
    var focusReads = 0

    init(text: String, selection: NSRange? = nil) {
        value = text
        currentSelection = selection ?? NSRange(location: text.utf16.count, length: 0)
    }

    func focusedElement() -> AXUIElement? {
        focusReads += 1
        return changeFocusAfterSelection && !selectionWrites.isEmpty ? otherElement : element
    }

    func isProtected(_ element: AXUIElement) -> Bool { protected }

    func text(in element: AXUIElement) -> String? {
        textReads += 1
        return value
    }

    func selection(in element: AXUIElement) -> NSRange? {
        selectionReads += 1
        return currentSelection
    }

    func canReplaceText(in element: AXUIElement) -> Bool { textIsSettable }

    func canSetSelection(in element: AXUIElement) -> Bool { true }

    func setSelection(_ range: NSRange, in element: AXUIElement) -> Bool {
        selectionWrites.append(range)
        if failFinalCaret && textWrites > 0 { return true }
        currentSelection = range
        return !(failFirstSelection && selectionWrites.count == 1)
    }

    func replaceSelectedText(_ text: String, in element: AXUIElement) -> Bool {
        textWrites += 1
        guard !failTextWrite else { return false }
        if ignoreTextWrite { return true }
        if insertInsteadOfReplacing {
            currentSelection = NSRange(location: NSMaxRange(currentSelection), length: 0)
        }
        typeText(text)
        return true
    }

    func typeText(_ text: String) {
        guard let range = Range(currentSelection, in: value) else { return }
        value.replaceSubrange(range, with: text)
        // Имитируем редактор, который оставляет замену выделенной после AX-записи.
        currentSelection = NSRange(location: currentSelection.location, length: text.utf16.count)
    }
}
