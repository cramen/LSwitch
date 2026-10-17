#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class RecipientOrdinaryLifecycleTests: XCTestCase {
    @MainActor
    func testCancellationBeforeWorkerArmDoesNotPublishOrReviveCapture() async throws {
        let fixture = try RecipientOrdinaryFixture(arm: false)
        XCTAssertFalse(fixture.capture.isCurrent)
        let request = RecipientCaptureArming(state: fixture.state, capture: fixture.capture,
                                            activation: try XCTUnwrap(fixture.bridge.prepareActivation()))
        request.cancel()
        let result = await withCheckedContinuation { continuation in
            request.register(continuation)
            request.run()
        }
        XCTAssertFalse(result)
        XCTAssertEqual(fixture.bridge.snapshot.phase, "lost")
        XCTAssertFalse(fixture.state.permitsMutation)
        XCTAssertEqual(fixture.attachment.counters.capturedEvents, 0)
    }

    @MainActor
    func testSuccessfulWorkerArmIsNotCancelledByLatePreparationTimer() async throws {
        let fixture = try RecipientOrdinaryFixture(arm: false)
        let request = RecipientCaptureArming(state: fixture.state, capture: fixture.capture,
                                            activation: try XCTUnwrap(fixture.bridge.prepareActivation()))
        let result = await withCheckedContinuation { continuation in
            request.register(continuation)
            request.run()
        }
        XCTAssertTrue(result)
        XCTAssertTrue(fixture.capture.isCurrent)
        request.expireIfPending()
        XCTAssertTrue(fixture.state.permitsMutation)
        try fixture.enqueue("after")
        XCTAssertEqual(fixture.attachment.counters.capturedEvents, 1)
    }

    @MainActor
    func testForwardedMouseDebtPreventsActivationWithoutStartingMutation() async throws {
        let fixture = try RecipientOrdinaryFixture(arm: false)
        let down = try RecoveryOperationFixture.event("")
        down.type = .leftMouseDown
        down.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        XCTAssertTrue(fixture.state.observe(type: .leftMouseDown, event: down, isHead: true))
        let request = RecipientCaptureArming(state: fixture.state, capture: fixture.capture,
                                            activation: try XCTUnwrap(fixture.bridge.prepareActivation()))
        let result = await withCheckedContinuation { continuation in
            request.register(continuation)
            request.run()
        }
        XCTAssertFalse(result)
        XCTAssertFalse(fixture.state.permitsMutation)
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
        down.type = .leftMouseUp
        XCTAssertTrue(fixture.state.observe(type: .leftMouseUp, event: down, isHead: true),
                      "Отказ prearm не должен захватывать release ранее пропущенного Down")
    }

    @MainActor
    func testForeignSenderWithTheSameMarkerIsCapturedInsteadOfTriggeringFlush() throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("kept")
        try fixture.accept()
        let forged = try XCTUnwrap(fixture.wake?.copy())
        forged.setIntegerValueField(.eventSourceUnixProcessID, value: 42)
        XCTAssertFalse(fixture.state.observe(type: .keyUp, event: forged, isHead: true, postOrdinary: { _ in
            XCTFail("Чужой sender не может запустить flush")
        }))
        XCTAssertNil(fixture.flush.terminalProof)
        XCTAssertEqual(fixture.attachment.counters.capturedEvents, 2)
        fixture.flush.requestRetention()
        fixture.flush.pollRetention()
        XCTAssertEqual(fixture.flush.terminalProof?.progress.totalEvents, 2)
    }

    @MainActor
    func testWakeWithoutCallbackProxyRetainsWithNoDispatch() throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("kept")
        try fixture.accept()
        try fixture.deliver(post: nil)
        XCTAssertEqual(try fixture.retainedText(), ["kept"])
        XCTAssertEqual(fixture.flush.terminalProof?.progress.attemptedPosts, 0)
    }

    @MainActor
    func testMarkerTombstoneSurvivesReleasedOwnerAfterSuccessfulOrdinaryRoute() throws {
        let (state, wake) = try completedState()
        XCTAssertFalse(state.observe(type: .keyUp, event: wake, isHead: true, postOrdinary: { _ in
            XCTFail("Поздний marker не должен открывать второй dispatch")
        }))
        XCTAssertTrue(state.observe(type: .keyDown, event: try RecoveryOperationFixture.event("next"), isHead: true))
        XCTAssertFalse(state.isProtectionAvailable)
        XCTAssertFalse(state.permitsMutation)
    }

    @MainActor
    func testCompletedNormalRouteKeepsUnownedInputPassingAcrossLossAndTeardown() throws {
        for cleaned in [false, true] {
            let (state, wake) = try completedState()
            if cleaned { state.recordCleanup() } else { state.markLost(.tapDisabled) }
            XCTAssertTrue(state.observe(type: .keyDown, event: try RecoveryOperationFixture.event("next"),
                                        isHead: true))
            XCTAssertFalse(state.observe(type: .keyUp, event: wake, isHead: true, postOrdinary: { _ in
                XCTFail("Поздний control остаётся tombstone после normal commit и teardown")
            }))
        }
    }

    @MainActor
    func testNoTerminalUntilActiveRouteFinishesCountCopyAndCounters() throws {
        let barrier = RecoveryRetirementBarrier(.afterCapture)
        let fixture = try RecipientOrdinaryFixture(observePhase: { barrier.observe($0) })
        let event = try RecoveryOperationFixture.event("kept")
        let router = fixture.router
        Thread {
            _ = router.route(type: .keyDown, event: event)
            barrier.finished.signal()
        }.start()
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)
        try fixture.accept()
        try fixture.deliver { _ in XCTFail("Proxy не используется, пока старый route не завершён") }
        XCTAssertNil(fixture.flush.terminalProof)
        XCTAssertTrue(fixture.flush.transport.retentionRequested)
        barrier.proceed.signal()
        XCTAssertEqual(barrier.finished.wait(timeout: .now() + 2), .success)
        fixture.flush.pollRetention()
        XCTAssertEqual(try fixture.retainedText(), ["kept"])
        XCTAssertEqual(fixture.flush.terminalProof?.progress.returnedPosts, 0)
    }

    @MainActor
    func testCancellationDuringLastPostCannotAuthorizeNormalRoute() throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("kept")
        try fixture.accept()
        try fixture.deliver { _ in fixture.flush.transport.requestRetention() }
        XCTAssertEqual(try fixture.retainedText(), ["kept"])
        XCTAssertEqual(fixture.flush.terminalProof?.progress.attemptedPosts, 1)
        XCTAssertEqual(fixture.flush.terminalProof?.progress.returnedPosts, 1)
        XCTAssertFalse(fixture.state.observe(type: .keyDown, event: try RecoveryOperationFixture.event("next"),
                                              isHead: true))
    }

    @MainActor
    private func completedState() throws -> (RecipientTapDriverState, CGEvent) {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("kept")
        try fixture.accept()
        try fixture.deliver()
        let proof = try XCTUnwrap(fixture.flush.terminalProof)
        XCTAssertTrue(fixture.coordinator.completeOrdinary(proof: proof))
        return (fixture.state, try XCTUnwrap(fixture.wake))
    }
}
#endif
