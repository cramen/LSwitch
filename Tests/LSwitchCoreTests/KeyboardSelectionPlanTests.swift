import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class KeyboardSelectionPlanTests: XCTestCase {
    func testGraphemesProduceExactUTF16SuffixRangesAndTaggedKeys() throws {
        let text = "🙂 e\u{301}x "
        let plan = try XCTUnwrap(KeyboardSelectionPlan(
            text: text, selection: NSRange(location: 7, length: 0), target: NSRange(location: 3, length: 4)
        ))
        XCTAssertEqual(plan.characterCount, 3)
        XCTAssertEqual(plan.ownedRanges, [
            NSRange(location: 7, length: 0), NSRange(location: 6, length: 1),
            NSRange(location: 5, length: 2), NSRange(location: 3, length: 4)
        ])
        let events = try XCTUnwrap(KeyboardEmitter.events(for: .selectCharacters(plan.characterCount)))
        XCTAssertEqual(events.filter { $0.type == .keyDown }.count, 3)
        XCTAssertTrue(events.allSatisfy { SyntheticEventMarker.isSynthetic($0) })
        XCTAssertEqual(events.first?.flags, .maskShift)
        XCTAssertEqual(events.last?.flags, [])
    }

    func testSplitSurrogateAndCombiningSequenceAreRejectedBeforeEmission() {
        for text in ["🙂", "e\u{301}"] {
            XCTAssertNil(KeyboardSelectionPlan(
                text: text, selection: NSRange(location: 2, length: 0), target: NSRange(location: 1, length: 1)
            ))
        }
    }

    func testSelectionMustEndAtOriginalCaretAndStayWithinBoundedText() {
        XCTAssertNil(KeyboardSelectionPlan(
            text: "ghbdtn suffix", selection: NSRange(location: 6, length: 0), target: NSRange(location: 0, length: 6)
        ))
        XCTAssertNil(KeyboardSelectionPlan(
            text: "abcdef", selection: NSRange(location: 6, length: 0), target: NSRange(location: 2, length: 3)
        ))
        XCTAssertNil(KeyboardSelectionPlan(
            text: "abcdef", selection: NSRange(location: 5, length: 1), target: NSRange(location: 2, length: 4)
        ))
        let long = String(repeating: "a", count: KeyboardSelectionPlan.maximumCharacters + 1)
        XCTAssertNil(KeyboardSelectionPlan(
            text: long, selection: NSRange(location: long.utf16.count, length: 0),
            target: NSRange(location: 0, length: long.utf16.count)
        ))
    }

    func testBidirectionalParagraphIsRejectedWithoutDisablingOtherParagraphs() {
        for prefix in ["שלום ", "مرحبا ", "\u{202E}", "\u{2067}"] {
            let text = prefix + "ghbdtn "
            XCTAssertNil(KeyboardSelectionPlan(
                text: text, selection: NSRange(location: text.utf16.count, length: 0),
                target: NSRange(location: prefix.utf16.count, length: 7)
            ))
        }
        let prefix = "שלום\n"
        let text = prefix + "ghbdtn "
        XCTAssertNotNil(KeyboardSelectionPlan(
            text: text, selection: NSRange(location: text.utf16.count, length: 0),
            target: NSRange(location: prefix.utf16.count, length: 7)
        ))
    }

    @MainActor
    func testKeyboardSelectionProfileIsChosenUpfrontOnlyForChrome() {
        XCTAssertTrue(AppProfiles.prefersKeyboardSelection(bundleID: "com.google.Chrome"))
        for bundleID in ["com.apple.Safari", "com.apple.TextEdit", "md.obsidian", "com.microsoft.VSCode"] {
            XCTAssertFalse(AppProfiles.prefersKeyboardSelection(bundleID: bundleID))
        }
    }
}
