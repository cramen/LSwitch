@testable import LSwitchCore
import XCTest

final class SelectionSettlementTests: XCTestCase {
    @MainActor
    func testTwoConsecutiveReadsAreRequiredAfterYield() async {
        let original = NSRange(location: 6, length: 0)
        let target = NSRange(location: 0, length: 6)
        let states = [target, original, target, target]
        var waits = 0
        let result = await SelectionSettlement.wait(
            expected: ("ghbdtn", target), allowedSelections: [original, target], isValid: { true },
            read: { ("ghbdtn", states[waits - 1]) }, pause: { waits += 1 }
        )
        XCTAssertTrue(result)
        XCTAssertEqual(waits, 4)
    }

    @MainActor
    func testUnknownTextOrSelectionStopsWithoutWaitingForCoincidentalMatch() async {
        let target = NSRange(location: 0, length: 6)
        for state in [("changed", target), ("ghbdtn", NSRange(location: 1, length: 2))] {
            var waits = 0
            let result = await SelectionSettlement.wait(
                expected: ("ghbdtn", target), allowedSelections: [target], isValid: { true },
                read: { state }, pause: { waits += 1 }
            )
            XCTAssertFalse(result)
            XCTAssertEqual(waits, 1)
        }
    }

    @MainActor
    func testNonSettlingStateIsBoundedAndContextIsCheckedAfterYield() async {
        let original = NSRange(location: 6, length: 0)
        let target = NSRange(location: 0, length: 6)
        for limit in [1, 10] {
            var waits = 0
            var reads = 0
            let result = await SelectionSettlement.wait(
                expected: ("ghbdtn", target), allowedSelections: [original, target],
                isValid: { waits < limit }, read: { reads += 1; return ("ghbdtn", original) },
                pause: { waits += 1 }
            )
            XCTAssertFalse(result)
            XCTAssertEqual(waits, min(limit, 4))
            XCTAssertEqual(reads, limit == 1 ? 0 : 4)
        }
    }
}
