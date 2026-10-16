import Foundation
@testable import LSwitchCore
import XCTest

final class ConversionRecoveryOwnerTests: XCTestCase {
    @MainActor
    func testMissingExternalOwnerRefusesBeforeFactoryOrLegacyHold() async {
        let fixture = TrackedConverterFixture()
        let converter = fixture.makeConverter(includeOwner: false)
        let result = await converter.trigger()
        XCTAssertEqual(result, .blockedBySafety)
        XCTAssertEqual(fixture.factoryCalls, 0)
        XCTAssertTrue(fixture.actions.isEmpty)
    }

    @MainActor
    func testOwnerRegistersSessionBeforeCaptureCanAdmitEvents() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.configureAdapter = { adapter in
            adapter.onActivate = {
                guard let context = fixture.latestContext else { return XCTFail("Нужен reservation") }
                XCTAssertNotNil(fixture.owner.session(for: context.admission))
                XCTAssertTrue(fixture.owner.isOccupied)
            }
        }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(fixture.adapters.first?.activations, 1)
        XCTAssertFalse(fixture.owner.isOccupied)
    }

    @MainActor
    func testPendingQueueOutlivesConverterAndBlocksANewConverterWithSameOwner() async throws {
        let fixture = TrackedConverterFixture()
        fixture.accessibility.handler = { request in
            guard let ledger = request.safetyLedger else { return .failed }
            _ = ledger.willSubmit(.text, operation: ledger.operation)
            return .failed
        }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        weak var previous = fixture.converter
        weak var session = try XCTUnwrap(fixture.sessions.first)
        weak var adapter = try XCTUnwrap(fixture.adapters.first)
        fixture.sessions.removeAll()
        fixture.adapters.removeAll()
        fixture.converter = fixture.makeConverter()
        XCTAssertNil(previous)
        XCTAssertNotNil(session)
        XCTAssertNotNil(adapter)
        XCTAssertTrue(fixture.owner.pendingSession === session)
        XCTAssertEqual(adapter?.queued, 2)
        XCTAssertEqual(adapter?.delivered, 0)
        let again = await fixture.converter.trigger()
        XCTAssertEqual(again, .recoveryRequired)
        XCTAssertEqual(fixture.factoryCalls, 1)
        XCTAssertFalse(fixture.actions.contains("legacyRelease"))
        XCTAssertEqual(adapter?.retentions, 1)
    }

    @MainActor
    func testRefusedFactoryReleasesOnlyEmptyReservationForNextInvocation() async {
        let fixture = TrackedConverterFixture()
        fixture.factoryAvailable = false
        let first = await fixture.converter.trigger()
        XCTAssertEqual(first, .blockedBySafety)
        XCTAssertFalse(fixture.owner.isOccupied)
        fixture.factoryAvailable = true
        fixture.succeed(fixture.accessibility)
        let second = await fixture.converter.trigger()
        XCTAssertEqual(second, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(fixture.factoryCalls, 2)
    }

    @MainActor
    func testFailedActivationStillHasAnExternalOwnerAndNeverStartsEngine() async {
        let fixture = TrackedConverterFixture()
        fixture.configureAdapter = { $0.activationAllowed = false }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertTrue(fixture.owner.hasPendingRecovery)
        XCTAssertNotNil(fixture.owner.pendingSession)
        XCTAssertEqual(fixture.adapters.first?.retentions, 1)
        XCTAssertTrue(fixture.accessibility.requests.isEmpty)
        XCTAssertFalse(fixture.actions.contains("legacyRelease"))
    }
}
