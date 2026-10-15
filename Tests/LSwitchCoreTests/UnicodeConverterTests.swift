import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class UnicodeConverterTests: XCTestCase {
    func testBothDirectionsPreservePrefixTailAndNextInput() async {
        for (original, converted) in [("ghbdtn", "привет"), ("цщкдв", "world")] {
            let editor = UnicodeTestEditor("😀 prefix \(original) ")
            let sourceID = original == "ghbdtn" ? "com.apple.keylayout.ABC" : "com.apple.keylayout.Russian"
            editor.source = UnicodeInputSource(identifier: sourceID, isKeyboardLayout: true)
            let result = await editor.converter().perform(editor.request(word: original))
            XCTAssertEqual(result, .success(.init(original: original, converted: converted, trailingText: " ")))
            XCTAssertEqual(editor.text, "😀 prefix \(converted) ")
            XCTAssertEqual(editor.selection, NSRange(location: editor.text.utf16.count, length: 0))
            XCTAssertEqual(editor.downCount, 1)
            XCTAssertEqual(editor.upCount, 1)
            XCTAssertEqual(editor.commands, [.select(original.count + 1)])
            XCTAssertEqual(editor.selectionPreflights, 1)
            XCTAssertEqual(editor.selectionPostflights, 1)
            editor.type("next")
            XCTAssertEqual(editor.text, "😀 prefix \(converted) next")
        }
    }

    func testRichNBSPTailIsPreservedByConversionAndExactInverse() async {
        let editor = UnicodeTestEditor("ghbdtn\u{00a0}")
        let result = await editor.converter().perform(editor.request())
        XCTAssertEqual(result, .success(.init(original: "ghbdtn", converted: "привет", trailingText: "\u{00a0}")))
        XCTAssertTrue(editor.text.utf16.elementsEqual("привет\u{00a0}".utf16))
        let undo = ConversionRequest(expectedWord: "привет", trailingText: "\u{00a0}",
                                     replacement: "ghbdtn", useSelection: false)
        let undone = await editor.converter().perform(undo)
        XCTAssertEqual(undone, .success(.init(original: "привет", converted: "ghbdtn", trailingText: "\u{00a0}")))
        XCTAssertTrue(editor.text.utf16.elementsEqual("ghbdtn\u{00a0}".utf16))
    }

    func testExplicitSelectionInMiddleRefusesBeforePreparationOrMutation() async {
        let editor = UnicodeTestEditor("before ghbdtn after")
        editor.selection = NSRange(location: 7, length: 6)
        let result = await editor.converter().perform(editor.request(manual: true))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.text, "before ghbdtn after")
        XCTAssertEqual(editor.selection, NSRange(location: 7, length: 6))
        XCTAssertEqual(editor.prepares, 0)
        XCTAssertEqual(editor.beginCount, 0)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertTrue(editor.commands.isEmpty)
    }

    func testMidDocumentWithoutSelectionRefusesBeforePreparationOrMutation() async {
        let editor = UnicodeTestEditor("ghbdtn later")
        editor.selection = NSRange(location: 7, length: 0)
        let result = await editor.converter().perform(editor.request())
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.prepares, 0)
        XCTAssertEqual(editor.beginCount, 0)
        XCTAssertTrue(editor.commands.isEmpty)
        XCTAssertEqual(editor.downCount, 0)
    }

    func testReceiptInverseDoesNotUseNativeUndoStack() async throws {
        let editor = UnicodeTestEditor("prefix ghbdtn ")
        let result = await editor.converter().perform(editor.request())
        guard case .success(let receipt) = result else { XCTFail("Нет receipt"); return }
        let undo = ConversionRequest(
            expectedWord: receipt.converted, trailingText: receipt.trailingText,
            replacement: receipt.original, sourceLayout: .russian, useSelection: false
        ).checkingTarget(receipt.targetIsCurrent)
        let result1 = await editor.converter().perform(undo)
        XCTAssertEqual(result1,
                       .success(.init(original: "привет", converted: "ghbdtn", trailingText: " ")))
        XCTAssertEqual(editor.text, "prefix ghbdtn ")
        XCTAssertEqual(editor.downCount, 2)
        XCTAssertEqual(editor.commands, [.select(7), .select(7)])
    }

    func testReceiptCannotUndoSameTextInAnotherDocument() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        let result = await editor.converter().perform(editor.request())
        guard case .success(let receipt) = result else { XCTFail("Нет receipt"); return }
        editor.document = "fixture:other"
        let undo = ConversionRequest(expectedWord: receipt.converted, trailingText: " ",
                                     replacement: receipt.original, useSelection: false)
            .checkingTarget(receipt.targetIsCurrent)
        let result2 = await editor.converter().perform(undo)
        XCTAssertEqual(result2, .blocked)
        XCTAssertEqual(editor.downCount, 1)
        XCTAssertEqual(editor.text, "привет ")
    }

    func testResultLeftSelectedIsCollapsedAndVerified() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.insertion = .selected
        let result = await editor.converter().perform(editor.request())
        XCTAssertEqual(result, .success(.init(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.commands, [.select(7), .collapse])
        XCTAssertEqual(editor.selectionPreflights, 2)
        XCTAssertEqual(editor.selectionPostflights, 2)
        XCTAssertEqual(editor.selection, NSRange(location: 7, length: 0))
        editor.type("мир")
        XCTAssertEqual(editor.text, "привет мир")
    }

    func testDelayedSinglePacketIsConfirmedWithoutSecondDown() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.insertion = .delayed
        let result = await editor.converter().perform(editor.request())
        XCTAssertEqual(result, .success(.init(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.downCount, 1)
        XCTAssertEqual(editor.upCount, 1)
        XCTAssertNil(editor.pendingText)
        editor.type("мир")
        XCTAssertEqual(editor.text, "привет мир")
    }

    func testCodeAndUnverifiedSourceRemainProtectedWhileManualUsesSameGuards() async {
        for automatic in [AutomaticTextContext.source(language: .swift, document: "fixture:one", characterCount: 11),
                          .unverifiedSource(document: "fixture:one"), .unknown] {
            let editor = UnicodeTestEditor("let ghbdtn ")
            editor.automatic = automatic
            let result3 = await editor.converter().perform(editor.request())
            XCTAssertEqual(result3, .blocked)
            XCTAssertEqual(editor.prepares, 0)
            XCTAssertEqual(editor.downCount, 0)
            let result4 = await editor.converter().perform(editor.request(manual: true))
            XCTAssertEqual(result4,
                           .success(.init(original: "ghbdtn", converted: "привет", trailingText: " ")))
        }
    }

    func testUnknownSnapshotAndCountMismatchRefuseBeforeMutation() async {
        for unknown in [true, false] {
            let editor = UnicodeTestEditor("ghbdtn ")
            if unknown { editor.provenance = .unverified } else { editor.characterCount = 100 }
            let result5 = await editor.converter().perform(editor.request())
            XCTAssertEqual(result5, .blocked)
            XCTAssertEqual(editor.prepares, 0)
            XCTAssertEqual(editor.beginCount, 0)
            XCTAssertTrue(editor.commands.isEmpty)
        }
    }

    func testIMEPayloadAndPreparationRefuseBeforeSelection() async {
        for condition in 0..<4 {
            let editor = UnicodeTestEditor("ghbdtn ")
            if condition == 0 { editor.source = nil }
            if condition == 1 { editor.postAllowed = false }
            if condition == 2 { editor.prepareAllowed = false }
            let request = condition == 3
                ? ConversionRequest(expectedWord: "ghbdtn", trailingText: " ",
                                    replacement: "привет\n", useSelection: false)
                : editor.request()
            let result6 = await editor.converter().perform(request)
            XCTAssertEqual(result6, .blocked)
            XCTAssertTrue(editor.commands.isEmpty)
            XCTAssertEqual(editor.downCount, 0)
        }
    }
}
