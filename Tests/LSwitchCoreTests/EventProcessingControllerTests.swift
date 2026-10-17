import CoreGraphics
import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

final class EventProcessingControllerTests: XCTestCase {
    @MainActor
    func testBeginBarrierDrainsPreviouslyQueuedMainDeliveryBeforeCaptureCanArm() async throws {
        let queue = DispatchQueue(label: "processing-test-before")
        let clock = EventProcessingTestClock()
        let controller = EventProcessingLeaseController(queue: queue, clock: { clock.read() })
        let trace = EventProcessingTrace()
        queue.async { DispatchQueue.main.async { trace.entries.append("previous") } }
        let pending = try await controller.begin(scope: EventProcessingTestFixture.scope())
        let lease = try XCTUnwrap(pending)
        XCTAssertEqual(trace.entries, ["previous"])
        XCTAssertTrue(controller.preCaptureReady(lease))
        XCTAssertTrue(controller.arm(lease, activate: { trace.entries.append("arm"); return true }))
        XCTAssertEqual(trace.entries, ["previous", "arm"])
    }

    @MainActor
    func testInputBeforeAndInsideActivationCannotHideBehindTheProcessingQueue() async throws {
        for duringActivation in [false, true] {
            let queue = DispatchQueue(label: "processing-test-arm")
            let clock = EventProcessingTestClock()
            let controller = EventProcessingLeaseController(queue: queue, clock: { clock.read() })
            let pending = try await controller.begin(scope: EventProcessingTestFixture.scope())
            let lease = try XCTUnwrap(pending)
            let event = try EventProcessingTestFixture.event()
            var activations = 0
            if !duringActivation { XCTAssertTrue(controller.observe(type: .keyDown, event: event)) }
            XCTAssertFalse(controller.arm(lease, activate: {
                activations += 1
                if duringActivation { XCTAssertTrue(controller.observe(type: .keyDown, event: event)) }
                return true
            }))
            XCTAssertEqual(activations, duringActivation ? 1 : 0)
            XCTAssertEqual(controller.state.metadata.payloadReads, 0)
            XCTAssertEqual(controller.state.metadata.failure, .inputBeforeCapture)
        }
    }

    @MainActor
    func testOutcomeClearsBeforeFIFOTailIncludingInputBetweenFlushAndHandoff() async throws {
        let queue = DispatchQueue(label: "processing-test-finish")
        let clock = EventProcessingTestClock()
        let controller = EventProcessingLeaseController(queue: queue, clock: { clock.read() })
        let pending = try await controller.begin(scope: EventProcessingTestFixture.scope())
        let lease = try XCTUnwrap(pending)
        XCTAssertTrue(controller.arm(lease, activate: { true }))
        let first = try EventProcessingTestFixture.event("a")
        let second = try EventProcessingTestFixture.event("b")
        XCTAssertTrue(controller.observe(type: .keyDown, event: first))
        let trace = EventProcessingTrace()
        let result = await controller.finish(lease, disposition: .delivered(nil), actions: .init(
            applyOutcome: {
                trace.entries.append("outcome")
                trace.buffered = ""
                XCTAssertTrue(controller.observe(type: .keyDown, event: second))
            }, reset: { trace.entries.append("reset") },
            consume: { trace.entries.append($0.characters); trace.buffered += $0.characters }
        ))
        XCTAssertEqual(result, .delivered)
        XCTAssertEqual(trace.entries, ["outcome", "a", "b"])
        XCTAssertEqual(trace.buffered, "ab")
        XCTAssertFalse(controller.observe(type: .keyDown, event: first), "Новый raw идёт обычному handler")
        queue.async { DispatchQueue.main.async { trace.entries.append("future") } }
        await withCheckedContinuation { continuation in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
        XCTAssertEqual(trace.entries, ["outcome", "a", "b", "future"])
        let repeated = await controller.finish(lease, disposition: .delivered(nil), actions: trace.actions)
        XCTAssertEqual(repeated, .stale)
        XCTAssertEqual(trace.entries, ["outcome", "a", "b", "future"])
    }

    @MainActor
    func testFocusInvalidationInsideOutcomeDiscardsOldTailBeforeAnyConsumer() async throws {
        let queue = DispatchQueue(label: "processing-test-focus")
        let clock = EventProcessingTestClock()
        let controller = EventProcessingLeaseController(queue: queue, clock: { clock.read() })
        let pending = try await controller.begin(scope: EventProcessingTestFixture.scope())
        let lease = try XCTUnwrap(pending)
        XCTAssertTrue(controller.arm(lease, activate: { true }))
        XCTAssertTrue(controller.observe(type: .keyDown, event: try EventProcessingTestFixture.event()))
        let trace = EventProcessingTrace()
        let result = await controller.finish(lease, disposition: .delivered(nil), actions: .init(
            applyOutcome: { trace.entries.append("outcome"); controller.state.invalidate(.focusChanged) },
            reset: { trace.entries.append("reset") }, consume: { trace.entries.append($0.characters) }
        ))
        XCTAssertEqual(result, .reset(.focusChanged))
        XCTAssertEqual(trace.entries, ["outcome", "reset"])
        XCTAssertFalse(controller.state.hasLease)
    }

    @MainActor
    func testCoreCallbackPassesOriginalEventWithoutCorrectionOrHandlerDuringLease() async throws {
        let core = EventTapCore { _ in XCTFail("Logical handler не вызывается") }
        let now = DispatchTime.now().uptimeNanoseconds
        let lease = try XCTUnwrap(core.processingLeases.state.begin(scope: EventProcessingTestFixture.scope(), at: now))
        XCTAssertTrue(core.processingLeases.state.arm(lease, at: now))
        core.recordLayoutChange(from: .english, to: .russian, since: now)
        let event = try EventProcessingTestFixture.event("g")
        event.timestamp = now
        let result = core.handleTapEvent(type: .keyDown, event: event)
        XCTAssertTrue(result?.takeUnretainedValue() === event)
        XCTAssertEqual(EventTapCore.makeRawEvent(type: .keyDown, event: event)?.characters, "g")
        let trace = EventProcessingTrace()
        let correction = QueuedInputCorrection(from: .english, to: .russian, startedAt: now, completedAt: now)
        let finish = await core.finishProcessingLease(
            lease, disposition: .delivered(correction), actions: trace.actions)
        XCTAssertEqual(finish, .delivered)
        XCTAssertEqual(trace.buffered, "п")
        XCTAssertEqual(EventTapCore.makeRawEvent(type: .keyDown, event: event)?.characters, "g")
    }

    @MainActor
    func testStoppedTapInvalidatesLogicalPayloadWithoutNativeHoldOrPost() async throws {
        let core = EventTapCore { _ in XCTFail("Handler не вызывается") }
        let now = DispatchTime.now().uptimeNanoseconds
        let lease = try XCTUnwrap(core.processingLeases.state.begin(scope: EventProcessingTestFixture.scope(), at: now))
        XCTAssertTrue(core.processingLeases.state.arm(lease, at: now))
        let event = try EventProcessingTestFixture.event()
        XCTAssertNotNil(core.handleTapEvent(type: .keyDown, event: event))
        core.stop()
        XCTAssertNotNil(core.handleTapEvent(type: .keyDown, event: event))
        XCTAssertEqual(core.processingLeases.state.metadata.payloadReads, 1)
        XCTAssertFalse(core.hasLegacyInputHold)
        let trace = EventProcessingTrace()
        let result = await core.finishProcessingLease(lease, disposition: .delivered(nil), actions: trace.actions)
        XCTAssertEqual(result, .reset(.stopped))
        XCTAssertEqual(trace.entries, ["outcome", "reset"])
    }
}
