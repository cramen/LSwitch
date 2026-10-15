import Foundation
@testable import LSwitchCore
import XCTest

final class NativeDispatchRegistryTests: XCTestCase {
    @MainActor
    func testPairReservationCreatesNoSubmissionAndCannotAdmitPreparedEvent() throws {
        let fixture = try NativeDispatchFixture()
        let registry = try fixture.registry()
        let pair = try XCTUnwrap(registry.reservePairs([fixture.keyPair])?.first)
        XCTAssertEqual(registry.entryCount, 2)
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
        XCTAssertEqual(registry.status(of: pair.down), .prepared)
        XCTAssertEqual(registry.status(of: pair.release), .prepared)
        XCTAssertEqual(registry.observe(marker: pair.down.marker, shape: fixture.keyPair.down, target: fixture.target),
                       .rejected(.notSubmitted))
        XCTAssertEqual(registry.status(of: pair.down), .prepared)
    }

    @MainActor
    func testBatchReservationIsAtomicAt256AndNeverEvictsEarlierSlots() throws {
        let fixture = try NativeDispatchFixture()
        let registry = try fixture.registry()
        XCTAssertNil(registry.reservePairs(Array(repeating: fixture.keyPair, count: 129)))
        XCTAssertEqual(registry.entryCount, 0)
        let pairs = try XCTUnwrap(registry.reservePairs(Array(repeating: fixture.keyPair, count: 128)))
        XCTAssertEqual(pairs.count, 128)
        XCTAssertEqual(registry.entryCount, 256)
        XCTAssertNil(registry.reservePairs([fixture.keyPair]))
        XCTAssertEqual(registry.status(of: try XCTUnwrap(pairs.first).down), .prepared)
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
    }

    @MainActor
    func testMalformedPairOrMarkerExhaustionCannotReservePartialDown() throws {
        let fixture = try NativeDispatchFixture()
        let markers = try XCTUnwrap(NativeDispatchMarkers(serialLimit: 3))
        let registry = try fixture.registry(markers: markers)
        let wrong = NativeDispatchPairShape(down: fixture.keyPair.down, release: fixture.modifierPair.release)
        XCTAssertNil(registry.reservePairs([fixture.keyPair, wrong]))
        XCTAssertEqual(registry.entryCount, 0)
        XCTAssertNotNil(registry.reservePairs([fixture.keyPair]))
        XCTAssertNil(registry.reservePairs([fixture.keyPair]))
        XCTAssertEqual(registry.entryCount, 2)
        XCTAssertNotNil(markers.reserve(1), "Неудачное резервирование не расходует половину пары")
        XCTAssertNil(markers.reserve(1))
    }

    @MainActor
    func testScopeInstanceForeignReservationAndDuplicateTokenCannotBind() throws {
        let fixture = try NativeDispatchFixture()
        let registry = try fixture.registry()
        let pair = try XCTUnwrap(registry.reservePairs([fixture.keyPair])?.first)
        let otherRegistry = try fixture.registry()
        let other = try XCTUnwrap(otherRegistry.reservePairs([fixture.keyPair])?.first)
        let token = try fixture.token()
        let wrong = RecoveryOperationTarget(operation: fixture.ledger.operation, target: try fixture.reusedTarget())
        XCTAssertFalse(registry.registerSubmitted(pair.down, token: token, scope: wrong))
        XCTAssertFalse(registry.registerSubmitted(other.down, token: token, scope: fixture.scope))
        let foreign = try NativeDispatchFixture()
        XCTAssertFalse(registry.registerSubmitted(pair.down, token: try foreign.token(), scope: fixture.scope))
        XCTAssertTrue(registry.registerSubmitted(pair.down, token: token, scope: fixture.scope))
        XCTAssertFalse(registry.registerSubmitted(pair.down, token: token, scope: fixture.scope))
        XCTAssertFalse(registry.registerSubmitted(pair.release, token: token, scope: fixture.scope))
        XCTAssertEqual(registry.status(of: pair.release), .prepared)
    }

    @MainActor
    func testCloseAloneDoesNotPretendSubmittedEventsWerePrevented() throws {
        let fixture = try NativeDispatchFixture()
        let registry = try fixture.registry()
        let pair = try XCTUnwrap(registry.reservePairs([fixture.keyPair])?.first)
        let down = try fixture.token()
        let release = try fixture.token(.balancingRelease)
        XCTAssertTrue(registry.registerSubmitted(pair.down, token: down, scope: fixture.scope))
        XCTAssertTrue(registry.registerSubmitted(pair.release, token: release, scope: fixture.scope))
        registry.closeGeneration()
        XCTAssertEqual(registry.status(of: pair.down), .submitted(down))
        XCTAssertEqual(registry.status(of: pair.release), .submitted(release))
        XCTAssertEqual(registry.observe(marker: pair.down.marker, shape: fixture.keyPair.down, target: fixture.target),
                       .prevented(down, .generationClosed))
        XCTAssertEqual(registry.observe(marker: pair.release.marker, shape: fixture.keyPair.release,
                                        target: fixture.target),
                       .prevented(release, .downNotAdmitted))
    }

    @MainActor
    func testAdmittedDownIsNotRetractedAndItsUpMayBeSubmittedAfterCloseOnce() throws {
        let fixture = try NativeDispatchFixture()
        let registry = try fixture.registry()
        let pair = try XCTUnwrap(registry.reservePairs([fixture.modifierPair, fixture.keyPair])?.first)
        let down = try fixture.token(.modifier)
        XCTAssertTrue(registry.registerSubmitted(pair.down, token: down, scope: fixture.scope))
        XCTAssertEqual(registry.observe(marker: pair.down.marker, shape: fixture.modifierPair.down,
                                        target: fixture.target), .admitted(down))
        registry.closeGeneration()
        XCTAssertEqual(registry.status(of: pair.down), .admitted(down))
        let release = try fixture.token(.balancingRelease)
        XCTAssertTrue(registry.registerSubmitted(pair.release, token: release, scope: fixture.scope))
        XCTAssertEqual(registry.observe(marker: pair.release.marker, shape: fixture.modifierPair.release,
                                        target: fixture.target), .admitted(release))
        XCTAssertEqual(registry.observe(marker: pair.release.marker, shape: fixture.modifierPair.release,
                                        target: fixture.target), .rejected(.duplicate))
        XCTAssertNil(registry.reservePairs([fixture.keyPair]))
        XCTAssertNil(fixture.ledger.decision, "Registry не завершает общий ledger")
    }

    @MainActor
    func testUpBeforeDownAdmissionClosesGenerationBeforeDelayedDownCanEnter() throws {
        let fixture = try NativeDispatchFixture()
        let registry = try fixture.registry()
        let pair = try XCTUnwrap(registry.reservePairs([fixture.keyPair])?.first)
        let down = try fixture.token()
        let release = try fixture.token(.balancingRelease)
        XCTAssertFalse(registry.registerSubmitted(pair.release, token: release, scope: fixture.scope))
        XCTAssertTrue(registry.registerSubmitted(pair.down, token: down, scope: fixture.scope))
        XCTAssertTrue(registry.registerSubmitted(pair.release, token: release, scope: fixture.scope))
        XCTAssertEqual(registry.observe(marker: pair.release.marker, shape: fixture.keyPair.release,
                                        target: fixture.target),
                       .prevented(release, .downNotAdmitted))
        XCTAssertTrue(registry.isClosed)
        XCTAssertEqual(registry.observe(marker: pair.down.marker, shape: fixture.keyPair.down, target: fixture.target),
                       .prevented(down, .generationClosed))
    }

    @MainActor
    func testShapeMismatchOrForeignProcessDoesNotCloseLegitimateSubmission() throws {
        let fixture = try NativeDispatchFixture()
        let registry = try fixture.registry()
        let pair = try XCTUnwrap(registry.reservePairs([fixture.keyPair])?.first)
        let down = try fixture.token()
        XCTAssertTrue(registry.registerSubmitted(pair.down, token: down, scope: fixture.scope))
        XCTAssertEqual(registry.observe(marker: pair.down.marker, shape: fixture.modifierPair.down,
                                        target: fixture.target), .rejected(.shapeMismatch))
        XCTAssertEqual(registry.observe(marker: pair.down.marker, shape: fixture.keyPair.down,
                                        target: try fixture.reusedTarget()), .rejected(.foreignTarget))
        XCTAssertEqual(registry.status(of: pair.down), .submitted(down))
        XCTAssertEqual(registry.observe(marker: pair.down.marker, shape: fixture.keyPair.down, target: fixture.target),
                       .admitted(down))
    }

    @MainActor
    func testReadOnlyMarkerLookupCannotClaimAnUnknownOrForeignEvent() throws {
        let fixture = try NativeDispatchFixture()
        let registry = try fixture.registry()
        let pair = try XCTUnwrap(registry.reservePairs([fixture.keyPair])?.first)
        XCTAssertTrue(registry.ownsReservedMarker(pair.down.marker, target: fixture.target))
        XCTAssertFalse(registry.ownsReservedMarker(0, target: fixture.target))
        XCTAssertFalse(registry.ownsReservedMarker(pair.down.marker, target: try fixture.reusedTarget()))
        XCTAssertEqual(registry.status(of: pair.down), .prepared)
    }
}
