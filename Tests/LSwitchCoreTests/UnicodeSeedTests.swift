import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class UnicodeSeedTests: XCTestCase {
    private enum Fault: CaseIterable { case focus, secure, document, source, lease, revision }

    func testExactSelectionAndResultSeedsStillRequireSeparateFreshObservations() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        var downAtPause = 0
        var resultObservations: [Int] = []
        editor.onDown = { downAtPause = editor.pauses }
        editor.onRead = {
            if editor.downCount > 0 { resultObservations.append(editor.pauses) }
        }
        let result = await editor.converter().perform(editor.request())
        XCTAssertEqual(result, .success(.init(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(downAtPause, 1)
        XCTAssertEqual(resultObservations, [downAtPause + 1, downAtPause + 2])
        XCTAssertEqual(editor.downCount, 1)
        XCTAssertEqual(editor.upCount, 1)
        editor.type("мир")
        XCTAssertEqual(editor.text, "привет мир")
    }

    func testMissingAfterCallbackDoesNotCreateSeedFromSuccessfulSendBoolean() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.omitSelectionAfterCallback = true
        var downAtPause = 0
        editor.onDown = { downAtPause = editor.pauses }
        let result = await editor.converter().perform(editor.request())
        XCTAssertEqual(result, .success(.init(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.selectionPostflights, 0)
        XCTAssertEqual(downAtPause, 2)
        XCTAssertEqual(editor.downCount, 1)
    }

    func testLaterPartialCallbackClearsEarlierExactSeed() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.selectionAfterCallbackCount = 2
        editor.beforeRepeatedSelectionAfter = { editor.selection = NSRange(location: 4, length: 3) }
        editor.onPause = { _ in
            if editor.downCount == 0 { editor.selection = NSRange(location: 0, length: 7) }
        }
        var downAtPause = 0
        editor.onDown = { downAtPause = editor.pauses }
        let result = await editor.converter().perform(editor.request())
        XCTAssertEqual(result, .success(.init(original: "ghbdtn", converted: "привет", trailingText: " ")))
        XCTAssertEqual(editor.selectionPostflights, 2)
        XCTAssertEqual(downAtPause, 2)
        XCTAssertEqual(editor.commands, [.select(7)])
    }

    func testFailedSendCannotConsumeObservedExactSelection() async {
        let editor = UnicodeTestEditor("ghbdtn ")
        editor.selectReturnValue = false
        let result = await editor.converter().perform(editor.request())
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.downCount, 0)
        XCTAssertEqual(editor.commands, [.select(7), .collapse])
        XCTAssertEqual(editor.selection, NSRange(location: 7, length: 0))
        editor.type("next")
        XCTAssertEqual(editor.text, "ghbdtn next")
    }

    func testSelectionSeedCannotBypassFreshTargetSourceAndLeaseGuards() async {
        for fault in Fault.allCases {
            let editor = UnicodeTestEditor("ghbdtn ")
            var payloadBeforeFault = 0
            var invalidated = false
            editor.onPause = { _ in
                guard !invalidated, editor.downCount == 0 else { return }
                invalidated = true
                payloadBeforeFault = editor.valueReads
                self.invalidate(fault, in: editor)
            }
            let result = await editor.converter().perform(editor.request())
            XCTAssertEqual(result, .failed, "\(fault)")
            XCTAssertEqual(editor.downCount, 0)
            XCTAssertEqual(editor.text, "ghbdtn ")
            switch fault {
            case .focus, .secure, .document:
                XCTAssertEqual(editor.valueReads, payloadBeforeFault)
                XCTAssertEqual(editor.commands, [.select(7)])
            case .source, .lease, .revision:
                XCTAssertEqual(editor.commands, [.select(7), .collapse])
                XCTAssertEqual(editor.selection, NSRange(location: 7, length: 0))
            }
        }
    }

    func testResultSeedCannotConfirmSuccessAfterContextChangesAtNextObservation() async {
        for fault in Fault.allCases {
            let editor = UnicodeTestEditor("ghbdtn ")
            var observedResult = false
            var invalidated = false
            editor.onRead = {
                if editor.downCount == 1 { observedResult = true }
            }
            editor.onPause = { _ in
                guard observedResult, !invalidated else { return }
                invalidated = true
                self.invalidate(fault, in: editor)
            }
            let result = await editor.converter().perform(editor.request())
            XCTAssertTrue(observedResult)
            XCTAssertTrue(invalidated)
            XCTAssertEqual(result, .failed, "\(fault)")
            XCTAssertEqual(editor.downCount, 1)
            XCTAssertEqual(editor.upCount, 1)
            XCTAssertEqual(editor.text, "привет ")
            XCTAssertEqual(editor.commands, [.select(7)])
        }
    }

    private func invalidate(_ fault: Fault, in editor: UnicodeTestEditor) {
        switch fault {
        case .focus: editor.contextValid = false
        case .secure: editor.protectedField = true
        case .document: editor.document = "fixture:other"
        case .source: editor.source = nil
        case .lease: editor.leaseValid = false
        case .revision: editor.revision += 1
        }
    }
}
