import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class UnicodeSelectionSettlementTests: XCTestCase {
    private let caret = NSRange(location: 7, length: 0)
    private let selected = NSRange(location: 0, length: 7)

    func testTwoStableCheckedReadsAreStillRequiredAfterSeparatePauses() async {
        var pauses = 0
        var reads = 0
        let result = await UnicodeSelectionSettlement.wait(
            expected: ("ghbdtn ", selected), allowedSelections: [caret, selected], canWait: { true },
            readChecked: {
                XCTAssertEqual(pauses, reads + 1)
                reads += 1
                return self.snapshot(selection: self.selected)
            }, pause: { pauses += 1 }
        )
        XCTAssertTrue(result)
        XCTAssertEqual(pauses, 2)
        XCTAssertEqual(reads, 2)
    }

    func testIntermediateOwnRangeResetsStabilityAndMaximumRemainsFour() async {
        let partial = NSRange(location: 4, length: 3)
        for states in [[selected, partial, selected, selected], [caret, caret, caret, caret]] {
            var reads = 0
            let result = await UnicodeSelectionSettlement.wait(
                expected: ("ghbdtn ", selected), allowedSelections: [caret, partial, selected], canWait: { true },
                readChecked: {
                    defer { reads += 1 }
                    return self.snapshot(selection: states[reads])
                }, pause: {}
            )
            XCTAssertEqual(result, states.last == selected)
            XCTAssertEqual(reads, 4)
        }
    }

    func testInvalidatedBoundaryAfterPauseCannotSupplyStableReadback() async {
        var boundaryValid = true
        var reads = 0
        let result = await UnicodeSelectionSettlement.wait(
            expected: ("ghbdtn ", selected), allowedSelections: [selected], canWait: { true },
            readChecked: {
                reads += 1
                return boundaryValid ? self.snapshot(selection: self.selected) : nil
            }, pause: { boundaryValid = false }
        )
        XCTAssertFalse(result)
        XCTAssertEqual(reads, 1)
    }

    func testCanonicalEquivalenceCannotSatisfyExactTextConfirmation() async {
        let original = "e\u{301}\u{327} "
        let foreign = "e\u{327}\u{301} "
        let range = NSRange(location: original.utf16.count, length: 0)
        var reads = 0
        let result = await UnicodeSelectionSettlement.wait(
            expected: (original, range), allowedSelections: [range], canWait: { true },
            readChecked: {
                reads += 1
                return UnicodeTextSnapshot(text: foreign, selection: range, characterCount: foreign.utf16.count,
                                           coordinateText: foreign, provenance: .chromiumTextControl)
            }, pause: {}
        )
        XCTAssertFalse(result)
        XCTAssertEqual(reads, 1)
    }

    private func snapshot(selection: NSRange) -> UnicodeTextSnapshot {
        UnicodeTextSnapshot(text: "ghbdtn ", selection: selection, characterCount: 7,
                            coordinateText: "ghbdtn ", provenance: .chromiumTextControl)
    }
}
