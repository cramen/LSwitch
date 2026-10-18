import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
private final class ProcessingFinishTrace {
    var entries: [String] = []
    var ready = false
    var queued: Task<Bool, Never>?
    var replacement: EventProcessingLease?
}

final class EventProcessingFinishTests: XCTestCase {
    @MainActor
    func testDidFinishPrecedesCallerResumeAndTaskScheduledByLastTailConsumer() async throws {
        let clock = EventProcessingTestClock()
        let controller = EventProcessingLeaseController(
            queue: DispatchQueue(label: "processing-finish-ready"), clock: { clock.read() }
        )
        let pending = try await controller.begin(scope: EventProcessingTestFixture.scope())
        let lease = try XCTUnwrap(pending)
        XCTAssertTrue(controller.arm(lease, activate: { true }))
        for text in ["first", "last"] {
            XCTAssertTrue(controller.observe(type: .keyDown, event: try EventProcessingTestFixture.event(text)))
        }
        let trace = ProcessingFinishTrace()
        let result = await controller.finish(lease, disposition: .delivered(nil), actions: .init(
            applyOutcome: { trace.entries.append("outcome") },
            reset: { XCTFail("Успешный хвост не сбрасывается") },
            consume: { raw in
                trace.entries.append(raw.characters)
                if raw.characters == "last" {
                    trace.queued = Task { @MainActor [weak trace] in
                        trace?.entries.append("queued")
                        return trace?.ready == true
                    }
                }
            }, didFinish: { trace.ready = true; trace.entries.append("ready") }
        ))
        // Caller не устанавливает ready после await: это уже поздно для task, созданного consume.
        XCTAssertEqual(result, .delivered)
        XCTAssertTrue(trace.ready)
        let queued = try XCTUnwrap(trace.queued)
        let observedReady = await queued.value
        XCTAssertTrue(observedReady)
        XCTAssertEqual(trace.entries, ["outcome", "first", "last", "ready", "queued"])
    }

    @MainActor
    func testDiscardOrFailureResetsBeforeDidFinishAndNeverPublishesTail() async throws {
        let clock = EventProcessingTestClock()
        let controller = EventProcessingLeaseController(
            queue: DispatchQueue(label: "processing-finish-reset"), clock: { clock.read() }
        )
        let pending = try await controller.begin(scope: EventProcessingTestFixture.scope())
        let lease = try XCTUnwrap(pending)
        XCTAssertTrue(controller.arm(lease, activate: { true }))
        XCTAssertTrue(controller.observe(type: .keyDown, event: try EventProcessingTestFixture.event("old")))
        controller.state.invalidate(.focusChanged)
        let trace = ProcessingFinishTrace()
        let result = await controller.finish(lease, disposition: .delivered(nil), actions: .init(
            applyOutcome: { trace.entries.append("outcome") },
            reset: { trace.entries.append("reset") }, consume: { _ in XCTFail("Отменённый хвост не публикуется") },
            didFinish: { trace.entries.append("finished") }
        ))
        XCTAssertEqual(result, .reset(.focusChanged))
        XCTAssertEqual(trace.entries, ["outcome", "reset", "finished"])
        XCTAssertFalse(controller.state.hasLease)
    }

    @MainActor
    func testForeignInitialFinishDoesNotInvokeAnyCallbackOrConsumeTheActiveLease() async throws {
        let clock = EventProcessingTestClock()
        let controller = EventProcessingLeaseController(
            queue: DispatchQueue(label: "processing-finish-foreign"), clock: { clock.read() }
        )
        let scope = try EventProcessingTestFixture.scope()
        let pending = await controller.begin(scope: scope)
        let lease = try XCTUnwrap(pending)
        let foreign = try XCTUnwrap(EventProcessingLeaseState().begin(scope: scope, at: 1))
        let actions = EventProcessingActions(
            applyOutcome: { XCTFail("Чужой lease") }, reset: { XCTFail("Чужой lease") },
            consume: { _ in XCTFail("Чужой lease") }, didFinish: { XCTFail("Чужой lease") }
        )
        let result = await controller.finish(foreign, disposition: .delivered(nil), actions: actions)
        XCTAssertEqual(result, .stale)
        XCTAssertTrue(controller.preCaptureReady(lease))
    }

    @MainActor
    func testSupersededLeaseDoesNotResetOrFinishTheReplacementScope() async throws {
        let clock = EventProcessingTestClock()
        let controller = EventProcessingLeaseController(
            queue: DispatchQueue(label: "processing-finish-superseded"), clock: { clock.read() }
        )
        let pending = try await controller.begin(scope: EventProcessingTestFixture.scope())
        let lease = try XCTUnwrap(pending)
        XCTAssertTrue(controller.arm(lease, activate: { true }))
        let replacementScope = try EventProcessingTestFixture.scope()
        let trace = ProcessingFinishTrace()
        let result = await controller.finish(lease, disposition: .delivered(nil), actions: .init(
            applyOutcome: {
                trace.entries.append("outcome")
                guard case .finished(.delivered) = controller.state.next(lease, at: clock.read()) else {
                    return XCTFail("Повторный вход должен завершить старый пустой record")
                }
                trace.replacement = controller.state.begin(scope: replacementScope, at: clock.read())
            }, reset: { trace.entries.append("wrong-reset") }, consume: { _ in XCTFail("Пустой хвост") },
            didFinish: { trace.entries.append("wrong-finish") }
        ))
        XCTAssertEqual(result, .stale)
        XCTAssertEqual(trace.entries, ["outcome"])
        XCTAssertTrue(controller.preCaptureReady(try XCTUnwrap(trace.replacement)))
    }
}
