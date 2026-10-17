import Foundation
@testable import LSwitchCore
import XCTest

final class ConverterTrackedFactoryTests: XCTestCase {
    @MainActor
    func testContextChangeWhileFactoryWaitsRefusesBeforeCaptureAndReleasesEmptyReservation() async {
        let fixture = TrackedConverterFixture()
        let entered = expectation(description: "Factory ожидает worker")
        var resume: CheckedContinuation<Void, Never>?
        fixture.beforeFactory = {
            await withCheckedContinuation { continuation in resume = continuation; entered.fulfill() }
        }
        let task = Task { await fixture.converter.trigger() }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertTrue(fixture.owner.isOccupied)
        XCTAssertNil(fixture.owner.pendingSession)
        let second = await fixture.makeConverter().trigger()
        XCTAssertEqual(second, .busy)
        XCTAssertEqual(fixture.factoryCalls, 0)
        fixture.safe = false
        resume?.resume()
        let result = await task.value
        XCTAssertEqual(result, .blockedBySafety)
        XCTAssertFalse(fixture.owner.isOccupied)
        XCTAssertTrue(fixture.sessions.isEmpty)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertTrue(fixture.accessibility.requests.isEmpty)
    }

    @MainActor
    func testCancellationWhileFactoryWaitsNeverActivatesCapture() async {
        let fixture = TrackedConverterFixture()
        let entered = expectation(description: "Factory ожидает worker")
        var resume: CheckedContinuation<Void, Never>?
        var activations = 0
        fixture.configureAdapter = { adapter in adapter.onActivate = { activations += 1 } }
        fixture.beforeFactory = {
            await withCheckedContinuation { continuation in resume = continuation; entered.fulfill() }
        }
        let task = Task { await fixture.converter.trigger() }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        XCTAssertTrue(fixture.owner.isOccupied)
        resume?.resume()
        let result = await task.value
        XCTAssertEqual(result, .blockedBySafety)
        XCTAssertEqual(activations, 0)
        XCTAssertFalse(fixture.owner.isOccupied)
        XCTAssertFalse(fixture.actions.contains("legacyRelease"))
        XCTAssertTrue(fixture.accessibility.requests.isEmpty)
    }

    @MainActor
    func testContextChangeAfterFactoryRegisteredSessionRetainsCapturedQueue() async {
        let fixture = TrackedConverterFixture()
        let entered = expectation(description: "Factory уже зарегистрировала Session")
        var resume: CheckedContinuation<Void, Never>?
        fixture.afterFactory = {
            await withCheckedContinuation { continuation in resume = continuation; entered.fulfill() }
        }
        let task = Task { await fixture.converter.trigger() }
        await fulfillment(of: [entered], timeout: 1)
        XCTAssertTrue(fixture.owner.isOccupied)
        XCTAssertEqual(fixture.adapters.first?.isCaptureValid, true)
        fixture.safe = false
        resume?.resume()
        let result = await task.value
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertTrue(fixture.owner.hasPendingRecovery)
        XCTAssertEqual(fixture.adapters.first?.queued, 2)
        XCTAssertEqual(fixture.adapters.first?.retentions, 1)
        XCTAssertTrue(fixture.accessibility.requests.isEmpty)
        XCTAssertFalse(fixture.actions.contains("drain"))
        XCTAssertFalse(fixture.actions.contains("legacyRelease"))
    }
}
