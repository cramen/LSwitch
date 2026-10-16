import Foundation
@testable import LSwitchCore
import XCTest

final class AXProfileSnapshotReaderTests: XCTestCase {
    @MainActor
    func testInvalidOrUnavailablePreflightCountNeverReadsPayloadOrSelection() {
        let cases: [Int?] = [nil, -1, Int.min, Int.max, AXProfileSnapshot.maximumUTF16Units + 1]
        for count in cases {
            var payloadReads = 0
            var selectionReads = 0
            let reader = AXProfileSnapshotReader(readCount: { count }, readText: { _ in
                payloadReads += 1
                return "not read"
            }, readSelection: { selectionReads += 1; return NSRange(location: 0, length: 0) })
            XCTAssertNil(reader.read(canRead: { true }))
            XCTAssertEqual(payloadReads, 0)
            XCTAssertEqual(selectionReads, 0)
        }
    }

    @MainActor
    func testRequestedRangeIsTheEntireBoundedDocumentIncludingExactLimit() throws {
        for text in ["", "😀 hello", String(repeating: "a", count: AXProfileSnapshot.maximumUTF16Units)] {
            var requests: [NSRange] = []
            var countReads = 0
            let count = text.utf16.count
            let reader = AXProfileSnapshotReader(readCount: { countReads += 1; return count }, readText: { range in
                requests.append(range)
                XCTAssertLessThanOrEqual(range.length, AXProfileSnapshot.maximumUTF16Units)
                return text
            }, readSelection: { NSRange(location: count, length: 0) })
            let snapshot = try XCTUnwrap(reader.read(canRead: { true }))
            XCTAssertTrue(snapshot.text.utf16.elementsEqual(text.utf16))
            XCTAssertEqual(requests, [NSRange(location: 0, length: count)])
            XCTAssertEqual(countReads, 2)
        }
    }

    @MainActor
    func testUnsupportedParameterizedReadDoesNotFallBackOrReadSelection() {
        var requests = 0
        var selections = 0
        let reader = AXProfileSnapshotReader(readCount: { 6 }, readText: { _ in requests += 1; return nil },
                                             readSelection: { selections += 1; return NSRange(location: 6, length: 0) })
        XCTAssertNil(reader.read(canRead: { true }))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(selections, 0)
    }

    @MainActor
    func testCountChangeAndWrongLengthRejectPartialOrIncoherentFullSnapshot() {
        for changedCount in [false, true] {
            var countReads = 0
            var selections = 0
            let reader = AXProfileSnapshotReader(readCount: {
                countReads += 1
                return countReads == 1 ? 6 : 7
            }, readText: { _ in changedCount ? "ghbdtn" : "short" }, readSelection: {
                selections += 1
                return NSRange(location: 6, length: 0)
            })
            XCTAssertNil(reader.read(canRead: { true }))
            XCTAssertEqual(selections, 0)
            XCTAssertEqual(countReads, changedCount ? 2 : 1)
        }
    }

    @MainActor
    func testLostGuardAfterCountPreventsPayloadAndAfterPayloadPreventsFurtherRead() {
        for afterPayload in [false, true] {
            var permitted = true
            var payloadReads = 0
            var countReads = 0
            var selections = 0
            let reader = AXProfileSnapshotReader(readCount: {
                countReads += 1
                if !afterPayload { permitted = false }
                return 1
            }, readText: { _ in payloadReads += 1; permitted = false; return "a" }, readSelection: {
                selections += 1
                return NSRange(location: 1, length: 0)
            })
            XCTAssertNil(reader.read(canRead: { permitted }))
            XCTAssertEqual(payloadReads, afterPayload ? 1 : 0)
            XCTAssertEqual(countReads, 1)
            XCTAssertEqual(selections, 0)
        }
    }

    @MainActor
    func testOversizedProviderReplyCannotBecomeAnAcceptedSnapshot() {
        var selectionReads = 0
        let reader = AXProfileSnapshotReader(readCount: { 1 }, readText: { range in
            XCTAssertEqual(range, NSRange(location: 0, length: 1))
            return String(repeating: "x", count: AXProfileSnapshot.maximumUTF16Units + 1)
        }, readSelection: { selectionReads += 1; return NSRange(location: 1, length: 0) })
        XCTAssertNil(reader.read(canRead: { true }))
        XCTAssertEqual(selectionReads, 0)
    }
}
