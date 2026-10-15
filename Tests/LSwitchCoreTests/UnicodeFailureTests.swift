import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class UnicodeFailureTests: XCTestCase {
    func testIgnoredPacketNeverRetriesAndRestoresOwnSelectionBeforeNextInput() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.insertion = .ignored
        let result1 = await editor.converter().perform(editor.request())
        XCTAssertEqual(result1, .failed)
        XCTAssertEqual(editor.downCount, 1)
        XCTAssertEqual(editor.upCount, 1)
        XCTAssertEqual(editor.commands, [.select(7), .collapse])
        XCTAssertEqual(editor.text, "ghbdtn ")
        editor.type("next")
        XCTAssertEqual(editor.text, "ghbdtn next")
    }

    func testPartialUnicodeDeliveryDoesNotRewriteUnknownText() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.insertion = .partial
        let result2 = await editor.converter().perform(editor.request())
        XCTAssertEqual(result2, .failed)
        XCTAssertEqual(editor.text, "пр")
        XCTAssertEqual(editor.downCount, 1)
        XCTAssertEqual(editor.commands, [.select(7)])
    }

    func testPartialNativeSelectionNeverPostsAndCleanupRestoresEOF() async {
        let editor = UnicodeTestEditor("prefix ghbdtn ")
        editor.selectionPrefixCount = 3
        let result3 = await editor.converter().perform(editor.request())
        XCTAssertEqual(result3, .failed)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.commands, [.select(7), .collapse])
        editor.type("next")
        XCTAssertEqual(editor.text, "prefix ghbdtn next")
    }

    func testSeventhYieldNativeBatchIsCancelledInOrderBeforeNextInput() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.selectionDelay = 7
        let result4 = await editor.converter().perform(editor.request())
        XCTAssertEqual(result4, .failed)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.commands, [.select(7), .collapse])
        XCTAssertEqual(editor.pauses, 6)
        XCTAssertEqual(editor.pending.map(\.command), [.select(7), .collapse])
        // Cached caret не подтверждает delivery. Получатель обработает ранее
        // поставленные batch и Right перед последующим выпущенным вводом.
        editor.advanceReceiver()
        XCTAssertTrue(editor.pending.isEmpty)
        XCTAssertEqual(editor.selection, NSRange(location: 7, length: 0))
        editor.type("next")
        XCTAssertEqual(editor.text, "ghbdtn next")
    }

    func testIgnoredSelectionStillReceivesIdempotentEOFRight() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.ignoreSelection = true
        let result5 = await editor.converter().perform(editor.request())
        XCTAssertEqual(result5, .failed)
        XCTAssertEqual(editor.commands, [.select(7), .collapse])
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.selection, NSRange(location: 7, length: 0))
    }

    func testForeignRangeDuringSettlementIsNotCollapsed() async {
        let editor = UnicodeTestEditor("prefix ghbdtn ")
        editor.onPause = { count in if count == 1 { editor.selection = NSRange(location: 0, length: 3) } }
        let result6 = await editor.converter().perform(editor.request())
        XCTAssertEqual(result6, .failed)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.commands, [.select(7)])
        XCTAssertEqual(editor.selection, NSRange(location: 0, length: 3))
    }

    func testFocusChangeAndDocumentChangeDuringSelectionPreventDownAndForeignCleanup() async {
        for changeDocument in [false, true] {
            let editor = UnicodeTestEditor("ghbdtn ")
            editor.onPause = { count in
                guard count == 1 else { return }
                if changeDocument { editor.document = "fixture:other" } else { editor.contextValid = false }
            }
            let result7 = await editor.converter().perform(editor.request())
            XCTAssertEqual(result7, .failed)
            XCTAssertEqual(editor.downCount, 0)
            XCTAssertEqual(editor.commands, [.select(7)])
        }
    }

    func testActiveSourceChangeBeforeDownCancelsAndCleansSelection() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.onPause = { _ in if editor.downCount == 0 { editor.source = nil } }
        let result8 = await editor.converter().perform(editor.request())
        XCTAssertEqual(result8, .failed)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.commands, [.select(7), .collapse])
        XCTAssertEqual(editor.selection, NSRange(location: 7, length: 0))
    }

    func testHoldCancellationAfterDownBalancesButDoesNotReturnReceipt() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.onDown = { editor.requestValid = false }
        let result9 = await editor.converter().perform(editor.request())
        XCTAssertEqual(result9, .failed)
        XCTAssertEqual(editor.downCount, 1)
        XCTAssertEqual(editor.upCount, 1)
        XCTAssertEqual(editor.text, "привет ")
        XCTAssertEqual(editor.commands, [.select(7)])
    }

    func testIdentityCannotChangeDuringFirstSnapshotWithSameBody() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.onRead = { editor.document = "fixture:other" }
        let result10 = await editor.converter().perform(editor.request())
        XCTAssertEqual(result10, .blocked)
        XCTAssertEqual(editor.prepares, 0)
        XCTAssertEqual(editor.beginCount, 0)
        XCTAssertTrue(editor.commands.isEmpty)
    }

    func testContextInvalidationDuringPacketPreparationPreventsMutation() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.onPrepare = { editor.requestValid = false }
        let result11 = await editor.converter().perform(editor.request())
        XCTAssertEqual(result11, .blocked)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.beginCount, 0)
        XCTAssertTrue(editor.commands.isEmpty)
    }

    func testIgnoredPacketPreservesExistingUserSelection() async {
        let editor = UnicodeTestEditor("before ghbdtn")
        editor.selection = NSRange(location: 7, length: 6)
        editor.insertion = .ignored
        let result12 = await editor.converter().perform(editor.request(manual: true))
        XCTAssertEqual(result12, .failed)
        XCTAssertTrue(editor.commands.isEmpty)
        XCTAssertEqual(editor.selection, NSRange(location: 7, length: 6))
        XCTAssertEqual(editor.downCount, 1)
    }

    func testTaskCancellationDuringSettlementPreventsDownButKeepsCleanup() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.onPause = { count in
            if count == 1 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let operation = Task { await editor.converter().perform(editor.request()) }
        let result = await operation.value
        XCTAssertTrue(operation.isCancelled)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.commands, [.select(7), .collapse])
        XCTAssertEqual(editor.selection, NSRange(location: 7, length: 0))
        editor.type("next")
        XCTAssertEqual(editor.text, "ghbdtn next")
    }

    func testCanonicalPrefixReorderDuringFinalSettlementCannotConfirmExactResult() async {
        let originalPrefix = "e\u{0301}\u{0327} "
        let foreignPrefix = "e\u{0327}\u{0301} "
        XCTAssertEqual(originalPrefix, foreignPrefix)
        XCTAssertEqual(originalPrefix.utf16.count, foreignPrefix.utf16.count)
        let editor = UnicodeTestEditor(originalPrefix + "ghbdtn ")
        var resultObserved = false
        editor.onRead = {
            if editor.downCount == 1 { resultObserved = true }
        }
        editor.onPause = { _ in
            if resultObserved { editor.text = foreignPrefix + "привет " }
        }
        let result = await editor.converter().perform(editor.request())
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(editor.text.utf16.elementsEqual((foreignPrefix + "привет ").utf16))
        XCTAssertEqual(editor.downCount, 1)
        XCTAssertEqual(editor.upCount, 1)
        XCTAssertEqual(editor.commands, [.select(7)])
    }

    func testForeignTextOrRangeInSelectionPostflightNeverReachesDown() async {
        for changesText in [false, true] {
            let editor = UnicodeTestEditor("prefix ghbdtn ")
            editor.afterSelectionCommand = { command in
                guard case .select = command else { return }
                if changesText { editor.text = "foreign text!!" }
                editor.selection = NSRange(location: 0, length: 3)
            }
            let result = await editor.converter().perform(editor.request())
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(editor.downCount, 0)
            XCTAssertEqual(editor.commands, [.select(7)])
            XCTAssertEqual(editor.selectionPostflights, 1)
            XCTAssertEqual(editor.selection, NSRange(location: 0, length: 3))
            XCTAssertEqual(editor.text, changesText ? "foreign text!!" : "prefix ghbdtn ")
        }
    }

    func testForeignCaretInCollapsePostflightIsNotMovedAgain() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.insertion = .selected
        editor.afterSelectionCommand = { command in
            if command == .collapse { editor.selection = NSRange(location: 1, length: 0) }
        }
        let result = await editor.converter().perform(editor.request())
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.downCount, 1)
        XCTAssertEqual(editor.commands, [.select(7), .collapse])
        XCTAssertEqual(editor.selection, NSRange(location: 1, length: 0))
        XCTAssertEqual(editor.text, "привет ")
    }

    func testLastPreDownBoundaryRejectsForeignRangeDocumentHoldAndSource() async {
        for change in 0..<4 {
            let editor = UnicodeTestEditor("ghbdtn ")
            editor.beforePacketCheck = {
                switch change {
                case 0: editor.selection = NSRange(location: 0, length: 2)
                case 1: editor.document = "fixture:other"
                case 2: editor.requestValid = false
                default: editor.source = nil
                }
            }
            let result = await editor.converter().perform(editor.request())
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(editor.downCount, 0)
            XCTAssertEqual(editor.upCount, 0)
            XCTAssertEqual(editor.text, "ghbdtn ")
            if change >= 2 {
                XCTAssertEqual(editor.commands, [.select(7), .collapse])
                XCTAssertEqual(editor.selection, NSRange(location: 7, length: 0))
            } else {
                XCTAssertEqual(editor.commands, [.select(7)])
            }
        }
    }

    func testDocumentChangesInsideReadAfterAwaitAreRejectedByReadBoundary() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.onPause = { count in
            if count == 1 { editor.onRead = { editor.document = "fixture:other" } }
        }
        let result = await editor.converter().perform(editor.request())
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.commands, [.select(7)])
        XCTAssertEqual(editor.text, "ghbdtn ")
    }
}
