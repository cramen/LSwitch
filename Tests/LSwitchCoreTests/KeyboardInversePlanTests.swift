import Foundation
@testable import LSwitchCore
import XCTest

final class KeyboardInversePlanTests: XCTestCase {
    func testInverseRejectsExistingMiddleSelectionEvenWhenForwardRangeIsValid() throws {
        let plan = try forward(text: "prefix ghbdtn suffix", selection: NSRange(location: 7, length: 6),
                               replacement: "привет")
        XCTAssertTrue(plan.wasSelection)
        XCTAssertNil(KeyboardSelectionPlan.inverse(of: plan))
    }

    func testInverseCountsGraphemesRatherThanUTF16AndEnforcesMaximum() throws {
        for count in [256, 257] {
            let original = String(repeating: "a", count: count)
            let converted = String(repeating: "🙂", count: count)
            let plan = try forward(text: original, selection: NSRange(location: 0, length: count),
                                   replacement: converted)
            let inverse = KeyboardSelectionPlan.inverse(of: plan)
            XCTAssertEqual(inverse?.characterCount, count == 256 ? count : nil)
            if count == 256 {
                XCTAssertEqual(inverse?.ownedRanges.last, NSRange(location: 0, length: count * 2))
            }
        }
    }

    func testInverseRejectsReplacementThatJoinsPrefixGrapheme() throws {
        let fixtures: [(String, (NSRange, String))] = [
            ("x a", (NSRange(location: 2, length: 1), "\u{301}")),
            ("👩x", (NSRange(location: 2, length: 1), "\u{200D}👩"))
        ]
        for (text, (selection, replacement)) in fixtures {
            let plan = try forward(text: text, selection: selection, replacement: replacement)
            XCTAssertNil(KeyboardSelectionPlan.inverse(of: plan))
        }
    }

    func testInversePreservesExactCombiningPrefixEmojiAndNBSPTail() throws {
        let text = "😀 e\u{301} ghbdtn\u{00a0}"
        let request = ConversionRequest(expectedWord: "ghbdtn", trailingText: " ", useSelection: false)
        let plan = try XCTUnwrap(AXReplacementPlan(
            text: text, selection: NSRange(location: text.utf16.count, length: 0),
            request: request, transform: request.converted
        ))
        let inverse = try XCTUnwrap(KeyboardSelectionPlan.inverse(of: plan))
        XCTAssertEqual(inverse.characterCount, 7)
        XCTAssertEqual(inverse.ownedRanges.last, NSRange(location: 6, length: 7))
        XCTAssertTrue(plan.receipt.trailingText.utf16.elementsEqual("\u{00a0}".utf16))
    }

    func testInverseRejectsBidirectionalGeometryIntroducedByReplacement() throws {
        let plan = try forward(text: "prefix a", selection: NSRange(location: 7, length: 1), replacement: "שלום")
        XCTAssertNil(KeyboardSelectionPlan.inverse(of: plan))
    }

    private func forward(text: String, selection: NSRange, replacement: String) throws -> AXReplacementPlan {
        let request = ConversionRequest(replacement: replacement)
        return try XCTUnwrap(AXReplacementPlan(
            text: text, selection: selection, request: request, transform: request.converted
        ))
    }
}
