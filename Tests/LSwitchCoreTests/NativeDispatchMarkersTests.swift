import Foundation
@testable import LSwitchCore
import XCTest

final class NativeDispatchMarkersTests: XCTestCase {
    func testMarkersAreExact52BitPositiveAndNeverReusedAcrossAllocators() throws {
        let first = try XCTUnwrap(NativeDispatchMarkers(serialLimit: 4))
        let second = try XCTUnwrap(NativeDispatchMarkers(serialLimit: 4))
        let firstMarkers = try XCTUnwrap(first.reserve(2))
        let later = try XCTUnwrap(first.reserve(2))
        let secondMarkers = try XCTUnwrap(second.reserve(4))
        let all = firstMarkers + later + secondMarkers
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertTrue(all.allSatisfy { $0 > 0 && $0 < (1 << 52) })
        XCTAssertTrue(all.allSatisfy { Int64(Double($0)) == $0 })
        XCTAssertNil(first.reserve(1))
        XCTAssertNil(second.reserve(1))
    }

    @MainActor
    func testClosedRegistryDoesNotRecycleItsMarkersForAnotherGeneration() throws {
        let fixture = try NativeDispatchFixture()
        let markers = try XCTUnwrap(NativeDispatchMarkers(serialLimit: 4))
        let first = try fixture.registry(markers: markers)
        let pair = try XCTUnwrap(first.reservePairs([fixture.keyPair])?.first)
        first.closeGeneration()
        let next = try NativeDispatchFixture()
        let second = try next.registry(markers: markers)
        let nextPair = try XCTUnwrap(second.reservePairs([next.keyPair])?.first)
        XCTAssertNotEqual(pair.down.marker, nextPair.down.marker)
        XCTAssertNotEqual(pair.release.marker, nextPair.release.marker)
        XCTAssertNil(first.reservePairs([fixture.keyPair]))
        XCTAssertNil(second.reservePairs([next.keyPair]))
    }

    func testInvalidQuotaAndOversizedReservationDoNotOverflowOrConsumePartialCapacity() throws {
        XCTAssertNil(NativeDispatchMarkers(serialLimit: 0))
        XCTAssertNil(NativeDispatchMarkers(serialLimit: UInt64.max))
        let markers = try XCTUnwrap(NativeDispatchMarkers(serialLimit: 2))
        XCTAssertNil(markers.reserve(0))
        XCTAssertNil(markers.reserve(-1))
        XCTAssertNil(markers.reserve(Int.max))
        XCTAssertEqual(markers.reserve(2)?.count, 2)
        XCTAssertNil(markers.reserve(1))
    }
}
