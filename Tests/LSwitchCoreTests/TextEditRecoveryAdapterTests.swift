#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class TextEditRecoveryAdapterTests: XCTestCase {
    @MainActor
    func testNativeProofIsConsumedBeforeSessionCompletionAndCompletedOFFStopsExactlyOnce() async throws {
        let fixture = try TextEditRecoveryAdapterFixture()
        await fixture.activate()
        try fixture.enqueue()
        let completion = try fixture.commit()
        try fixture.driver.deliverWake()
        let result = await completion.waitForTerminal()
        XCTAssertEqual(result, .locallyDispatched)
        XCTAssertTrue(fixture.adapter.ordinaryCompleted)
        XCTAssertFalse(fixture.coordinator.hasPendingRecovery)
        let proof = try XCTUnwrap(fixture.driver.flush?.terminalProof)
        XCTAssertFalse(fixture.coordinator.completeOrdinary(proof: proof), "Native waiter уже потребил proof")
        fixture.adapter.interrupt(.off)
        let stopped = await fixture.adapter.awaitRecovery()
        XCTAssertTrue(stopped)
        XCTAssertTrue(fixture.adapter.driverStopped)
        XCTAssertEqual(fixture.driver.stops, 1)
        let repeated = await fixture.adapter.awaitRecovery()
        XCTAssertTrue(repeated)
        XCTAssertEqual(fixture.driver.stops, 1)
    }

    @MainActor
    func testSessionCancellationImmediatelyForwardsRetentionToNativeAndKeepsTheSameOrdinaryClaim() async throws {
        let fixture = try TextEditRecoveryAdapterFixture()
        await fixture.activate()
        try fixture.enqueue()
        let completion = try fixture.commit()
        let entered = expectation(description: "Session ожидает отдельный handle")
        let task = Task { entered.fulfill(); return await completion.waitForTerminal() }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        XCTAssertEqual(fixture.driver.flush?.transport.retentionRequested, true)
        fixture.driver.flush?.pollRetention()
        let result = await task.value
        XCTAssertEqual(result, .retainedFailure)
        XCTAssertTrue(fixture.adapter.adopted)
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
        XCTAssertEqual(fixture.coordinator.metadata?.ordinaryDelivery?.attemptedPosts, 0)
        XCTAssertEqual(fixture.ledger.inputOwner, .ordinaryDelivery)
        XCTAssertNil(fixture.ledger.claimInput(operation: fixture.ledger.operation))
        XCTAssertNil(fixture.coordinator.revealedProjection)
    }

    @MainActor
    func testRetainImmediatelyStopsCapturePayloadBeforeRetirementTaskRuns() async throws {
        let fixture = try TextEditRecoveryAdapterFixture()
        await fixture.activate()
        try fixture.enqueue()
        _ = fixture.ledger.finish(operation: fixture.ledger.operation, text: .unknown,
                                   cleanup: .recoveryUnconfirmed, ordinaryRouteValid: false)
        let claim = try XCTUnwrap(fixture.ledger.claimInput(operation: fixture.ledger.operation))
        fixture.adapter.retainForRecovery(claim: claim)
        let later = try EventProcessingTestFixture.event("later")
        XCTAssertFalse(fixture.driver.state.observe(type: .keyDown, event: later, isHead: true))
        XCTAssertEqual(fixture.attachment.counters.capturedEvents, 1)
        XCTAssertEqual(fixture.attachment.counters.payloadCountReads, 1)
        let adopted = await fixture.adapter.awaitRecovery()
        XCTAssertTrue(adopted)
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
        XCTAssertEqual(fixture.ledger.inputOwner, .recovery)
        XCTAssertEqual(fixture.driver.stops, 0, "Quarantine сохраняется без OFF/TCC")
    }

    @MainActor
    func testTaskCreatedByLogicalTailCanBeginNextInvocationAfterExactFinish() async throws {
        let fixture = try TextEditRecoveryAdapterFixture()
        let runtime = TextEditRecoveryRuntime(testDocument: URL(fileURLWithPath: "/tmp/textedit-owned-fixture.txt"),
                                              eventTap: { nil }, currentSafety: { true })
        let invocation = try XCTUnwrap(runtime.beginInvocation())
        runtime.attempt?.adapter = fixture.adapter
        await fixture.activate()
        try fixture.enqueue("x")
        let completion = try fixture.commit()
        try fixture.driver.deliverWake()
        let delivered = await completion.waitForTerminal()
        XCTAssertEqual(delivered, .locallyDispatched)
        let ran = expectation(description: "Новый trigger после logical tail")
        let finished = await runtime.finishInvocation(invocation, outcome: .converted(original: "g", converted: "п"),
            actions: .init(applyOutcome: { _ in }, reset: { XCTFail("Healthy tail не сбрасывается") }, consume: { raw in
                XCTAssertEqual(raw.characters, "x")
                XCTAssertEqual(fixture.driver.stops, 1, "Driver остановлен до логического tail")
                Task { @MainActor in
                    XCTAssertNotNil(runtime.beginInvocation(), "Хвост не получает ложный busy от старого attempt")
                    ran.fulfill()
                }
            }))
        XCTAssertTrue(finished)
        await fulfillment(of: [ran], timeout: 1)
    }
}
#endif
