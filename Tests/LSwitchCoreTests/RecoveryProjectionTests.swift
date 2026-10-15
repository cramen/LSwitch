import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryProjectionTests: XCTestCase {
    private struct ReadCounts {
        let expected: Int
        let actual: Int
        let rechecked: Int
    }

    func testValidPayloadPreservesExactUnitsAndOnlyClaimsEventEvidence() {
        for text in ["hello", "привет", "😀", "e\u{301}", "\u{A0}", "👩‍💻"] {
            let units = Array(text.utf16)
            guard case .unicodeFragment(let fragment) = content(units) else {
                XCTFail("Валидный payload должен остаться отдельным Unicode-фрагментом")
                continue
            }
            XCTAssertEqual(Array(fragment.text.utf16), units)
            XCTAssertEqual(fragment.evidence, .eventPayloadOnly)
        }
    }

    func testInvalidSurrogatesAreNotRepairedOrCombinedAcrossEvents() {
        let invalid: [[UInt16]] = [[0xD800], [0xDC00], [0xDC00, 0xD800], [0xD800, 0x61], [0x61, 0xDC00]]
        for units in invalid { XCTAssertEqual(content(units), .unresolved(.invalidUTF16)) }
        XCTAssertEqual(content([0xD83D]), .unresolved(.invalidUTF16))
        XCTAssertEqual(content([0xDE00]), .unresolved(.invalidUTF16))
        guard case .unicodeFragment(let intact) = content([0xD83D, 0xDE00]) else {
            XCTFail("Целая surrogate-пара внутри одного события допустима")
            return
        }
        XCTAssertEqual(Array(intact.text.utf16), [0xD83D, 0xDE00])
    }

    func testCanonicalEquivalenceDoesNotEraseDifferentEventPayloads() {
        let decomposed = RecoveryUnicodeFragment(text: "e\u{301}")
        let composed = RecoveryUnicodeFragment(text: "é")
        XCTAssertNotEqual(decomposed, composed)
        XCTAssertNotEqual(RecoveryProjectionContent.unicodeFragment(decomposed), .unicodeFragment(composed))
        XCTAssertEqual(Array(decomposed.text.utf16), [0x65, 0x301])
    }

    func testEmptyAndControlPayloadsRemainExplicitUnresolvedEntries() {
        XCTAssertEqual(content([]), .unresolved(.missingUnicodePayload))
        let controls: [UInt16] = [0, 9, 10, 13, 0x7F, 0x85, 0xF700]
        for unit in controls {
            XCTAssertEqual(content([unit]), .unresolved(.controlUnicodePayload))
        }
    }

    func testCountMismatchCannotPublishPartialOrPaddedPayload() {
        let counts = [
            ReadCounts(expected: 2, actual: 1, rechecked: 2),
            ReadCounts(expected: 2, actual: 3, rechecked: 2),
            ReadCounts(expected: 2, actual: 2, rechecked: 3),
            ReadCounts(expected: 1, actual: 1, rechecked: 1),
            ReadCounts(expected: -1, actual: -1, rechecked: -1)
        ]
        for count in counts {
            XCTAssertEqual(RecoveryUnicodeProjection.content(
                units: [0x61, 0x62], expectedCount: count.expected,
                actualCount: count.actual, recheckedCount: count.rechecked
            ), .unresolved(.unicodeReadInconsistent))
        }
    }

    func testEveryPayloadContainerRedactsDescriptionAndDebugDescription() {
        let secret = "DO_NOT_DISCLOSE_проекция_😀"
        let fragment = RecoveryUnicodeFragment(text: secret)
        let value = RecoveryProjectionContent.unicodeFragment(fragment)
        let entry = RecoveryProjectionEntry(ordinal: 0, content: value)
        let projection = RecoveryProjection(recordIdentifier: UUID(), entries: [entry], failure: nil)
        let outputs = [
            fragment.description, fragment.debugDescription, String(describing: fragment), String(reflecting: fragment),
            value.description, value.debugDescription, String(describing: value), String(reflecting: value),
            entry.description, entry.debugDescription, String(describing: entry), String(reflecting: entry),
            projection.description, projection.debugDescription,
            String(describing: projection), String(reflecting: projection)
        ]
        for output in outputs {
            XCTAssertFalse(output.contains(secret))
            XCTAssertTrue(output.contains("redacted"))
        }
        XCTAssertEqual(fragment.text, secret)
    }

    private func content(_ units: [UInt16]) -> RecoveryProjectionContent {
        RecoveryUnicodeProjection.content(
            units: units, expectedCount: units.count, actualCount: units.count, recheckedCount: units.count
        )
    }
}
