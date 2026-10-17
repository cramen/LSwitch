import Foundation
@testable import LSwitchCore
import XCTest

final class ConverterTrackedTransportTests: XCTestCase {
    @MainActor
    func testPreclaimRetirementKeepsConfirmedRecoveryOwnershipMetadata() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.configureAdapter = { adapter in
            adapter.beforeClaim = { fixture.sessions.first?.retainIfUnfinished() }
        }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertEqual(fixture.ledgers.first?.inputOwner, .recovery)
        XCTAssertEqual(fixture.adapters.first?.retainedClaim?.owner, .recovery)
        XCTAssertEqual(fixture.sessions.first?.ordinaryOwnershipUnconfirmed, false)
        XCTAssertEqual(fixture.sessions.first?.ordinaryTransportRetained, false)
        XCTAssertEqual(fixture.adapters.first?.retentions, 1)
        XCTAssertNil(fixture.adapters.first?.acceptedClaim)
        XCTAssertNil(fixture.adapters.first?.transport)
        XCTAssertEqual(fixture.adapters.first?.queued, 2)
        XCTAssertEqual(fixture.adapters.first?.delivered, 0)
        XCTAssertTrue(fixture.owner.hasPendingRecovery)
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertFalse(fixture.actions.contains("sound"))
    }

    @MainActor
    func testInputDuringPreparationAndTISIsIncludedBeforeCaptureCutoff() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.configureAdapter = { adapter in
            adapter.onPrepare = {
                XCTAssertTrue(adapter.isCaptureValid)
                adapter.queued += 3
            }
        }
        fixture.onSwitch = {
            XCTAssertEqual(fixture.adapters.first?.isCaptureValid, true)
            fixture.adapters.first?.queued += 4
        }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(fixture.adapters.first?.delivered, 9)
        XCTAssertEqual(fixture.adapters.first?.isCaptureValid, false)
        XCTAssertEqual(fixture.actions.filter { $0 == "deliver" }.count, 1)
    }

    @MainActor
    func testDelayedDeliveryKeepsOwnerBusyAndDoesNotPublishSuccessEarly() async throws {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        let accepted = expectation(description: "Transport принял владение")
        fixture.configureAdapter = { adapter in
            adapter.completesImmediately = false
            adapter.onAccepted = { accepted.fulfill() }
        }
        let task = Task { await fixture.converter.trigger() }
        await fulfillment(of: [accepted], timeout: 1)
        let adapter = try XCTUnwrap(fixture.adapters.first)
        XCTAssertTrue(fixture.owner.isOccupied)
        XCTAssertTrue(fixture.owner.hasPendingTransport)
        XCTAssertTrue(fixture.owner.pendingSession === fixture.sessions.first)
        XCTAssertEqual(fixture.ledgers.first?.inputOwner, .ordinaryDelivery)
        XCTAssertEqual(adapter.queued, 2)
        XCTAssertEqual(adapter.delivered, 0)
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertTrue(fixture.converter.modeCache.isEmpty)
        XCTAssertFalse(fixture.actions.contains("sound"))
        let other = fixture.makeConverter()
        let repeated = await other.trigger()
        XCTAssertEqual(repeated, .busy)
        XCTAssertEqual(fixture.factoryCalls, 1)
        adapter.completeTransport(.locallyDispatched)
        let result = await task.value
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertFalse(fixture.owner.isOccupied)
        XCTAssertFalse(fixture.owner.hasPendingTransport)
        XCTAssertNil(fixture.owner.pendingSession)
        XCTAssertNotNil(fixture.undoStore.pendingUndo())
        XCTAssertEqual(Array(fixture.actions.suffix(2)), ["deliver", "sound"])
    }

    @MainActor
    func testClaimCallbackDoesNotInvokeExternalRouteChecks() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        var insideClaimSection = false
        fixture.configureAdapter = { adapter in
            adapter.onRouteCheck = { XCTAssertFalse(insideClaimSection) }
            adapter.beforeClaim = { insideClaimSection = true }
            adapter.onCommit = { insideClaimSection = false }
        }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertFalse(insideClaimSection)
    }

    @MainActor
    func testTransportFailureKeepsSameClaimAndQueueAfterConverterDeinitialization() async throws {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        let accepted = expectation(description: "Transport принял владение")
        fixture.configureAdapter = { adapter in
            adapter.completesImmediately = false
            adapter.onAccepted = { accepted.fulfill() }
        }
        var task: Task<Converter.Outcome, Never>? = Task { await fixture.converter.trigger() }
        await fulfillment(of: [accepted], timeout: 1)
        let adapter = try XCTUnwrap(fixture.adapters.first)
        let claim = adapter.acceptedClaim
        adapter.completeTransport(.retainedFailure)
        let result = await task?.value
        XCTAssertEqual(result, .recoveryRequired)
        task = nil
        weak var previous = fixture.converter
        weak var session = try XCTUnwrap(fixture.sessions.first)
        fixture.sessions.removeAll()
        fixture.adapters.removeAll()
        fixture.converter = fixture.makeConverter()
        XCTAssertNil(previous)
        XCTAssertNotNil(session)
        XCTAssertTrue(fixture.owner.pendingSession === session)
        XCTAssertEqual(session?.ordinaryTransportRetained, true)
        XCTAssertEqual(session?.ordinaryOwnershipUnconfirmed, false)
        XCTAssertTrue(fixture.owner.hasPendingRecovery)
        XCTAssertFalse(fixture.owner.hasPendingTransport)
        XCTAssertEqual(adapter.acceptedClaim, claim)
        XCTAssertEqual(fixture.ledgers.first?.inputOwner, .ordinaryDelivery)
        XCTAssertEqual(adapter.queued, 2)
        XCTAssertEqual(adapter.delivered, 0)
        XCTAssertEqual(adapter.retentions, 0)
        XCTAssertNil(adapter.retainedClaim)
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertTrue(fixture.converter.modeCache.isEmpty)
        XCTAssertFalse(fixture.actions.contains("sound"))
        XCTAssertFalse(fixture.actions.contains("legacyRelease"))
        let next = await fixture.converter.trigger()
        XCTAssertEqual(next, .recoveryRequired)
        XCTAssertEqual(fixture.factoryCalls, 1)
    }

    @MainActor
    func testCancellationRequestsRetentionWithoutReleasingOrResolvingPendingTransport() async throws {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        let accepted = expectation(description: "Transport принял владение")
        fixture.configureAdapter = { adapter in
            adapter.completesImmediately = false
            adapter.onAccepted = { accepted.fulfill() }
        }
        let task = Task { await fixture.converter.trigger() }
        await fulfillment(of: [accepted], timeout: 1)
        let adapter = try XCTUnwrap(fixture.adapters.first)
        task.cancel()
        XCTAssertEqual(adapter.transport?.retentionRequested, true)
        XCTAssertTrue(fixture.owner.isOccupied)
        XCTAssertTrue(fixture.owner.hasPendingTransport)
        XCTAssertEqual(adapter.queued, 2)
        XCTAssertEqual(adapter.retentions, 0)
        XCTAssertFalse(fixture.actions.contains("sound"))
        adapter.completeTransport(.retainedFailure)
        let result = await task.value
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertEqual(fixture.ledgers.first?.inputOwner, .ordinaryDelivery)
        XCTAssertTrue(fixture.owner.hasPendingRecovery)
        XCTAssertEqual(adapter.retentions, 0)
    }

    @MainActor
    func testRetirementReentryAfterClaimRequestsRetentionOnAcceptedTransport() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.configureAdapter = { adapter in
            adapter.onCommit = { fixture.sessions.first?.retainIfUnfinished() }
            adapter.completesImmediately = false
            adapter.onAccepted = {
                Task { @MainActor in
                    XCTAssertEqual(adapter.transport?.retentionRequested, true)
                    adapter.completeTransport(.retainedFailure)
                }
            }
        }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertEqual(fixture.adapters.first?.retentions, 0)
        XCTAssertEqual(fixture.adapters.first?.queued, 2)
        XCTAssertEqual(fixture.ledgers.first?.inputOwner, .ordinaryDelivery)
        XCTAssertNil(fixture.undoStore.pendingUndo())
    }

    @MainActor
    func testCancellationCannotUndoAlreadyCompletedLocalDelivery() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        var task: Task<Converter.Outcome, Never>?
        fixture.configureAdapter = { adapter in
            adapter.onAccepted = {
                adapter.completeTransport(.locallyDispatched)
                task?.cancel()
            }
        }
        task = Task { await fixture.converter.trigger() }
        let result = await task?.value
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertFalse(fixture.owner.isOccupied)
        XCTAssertEqual(fixture.adapters.first?.transport?.retentionRequested, false)
        XCTAssertEqual(fixture.adapters.first?.delivered, 2)
    }
}
