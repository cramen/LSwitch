#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class AtomicProcessingArmLifecycleTests: XCTestCase {
    @MainActor
    func testCancelledQueuedWorkerCannotPublishOrReadAnyLaterLogicalPayload() async throws {
        let fixture = try AtomicProcessingArmFixture()
        let request = try fixture.request()
        request.cancel()
        let accepted = await withCheckedContinuation { continuation in
            request.register(continuation)
            request.run()
        }
        XCTAssertFalse(accepted)
        XCTAssertFalse(fixture.prepared.isCurrent)
        XCTAssertTrue(fixture.state.observe(type: .keyDown, event: try EventProcessingTestFixture.event(), at: 1))
        XCTAssertEqual(fixture.state.metadata.payloadReads, 0)
        XCTAssertEqual(fixture.recipient.attachment.counters.payloadCountReads, 0)
        XCTAssertEqual(fixture.recipient.ledger.submissionCount, 0)
    }

    @MainActor
    func testCancellationAfterArmKeepsNativePrefixAndStopsNewLogicalReads() async throws {
        let fixture = try AtomicProcessingArmFixture()
        let request = try fixture.request()
        let accepted = await withCheckedContinuation { continuation in
            request.register(continuation)
            request.run()
        }
        XCTAssertTrue(accepted)
        request.expireIfPending()
        XCTAssertTrue(fixture.prepared.isCurrent, "Поздний preparation timer не отменяет законченный arm")
        let first = try EventProcessingTestFixture.event("kept")
        XCTAssertTrue(fixture.state.observe(type: .keyDown, event: first, at: 1))
        XCTAssertFalse(fixture.recipient.state.observe(type: .keyDown, event: first, isHead: true))
        request.cancel()
        XCTAssertTrue(fixture.state.observe(type: .keyDown, event: try EventProcessingTestFixture.event(), at: 2))
        XCTAssertEqual(fixture.state.metadata.payloadReads, 1)
        XCTAssertEqual(fixture.state.metadata.eventCount, 0)
        XCTAssertEqual(fixture.recipient.attachment.counters.capturedEvents, 1)
        XCTAssertFalse(fixture.recipient.capture.isCurrent)
    }

    @MainActor
    func testStaleWrapperCannotPublishOrInvalidateReplacementLogicalLease() throws {
        let fixture = try AtomicProcessingArmFixture()
        XCTAssertTrue(fixture.state.claimFinish(fixture.lease, disposition: .discard, at: 1))
        guard case .finished(.discarded) = fixture.state.next(fixture.lease, at: 1) else {
            return XCTFail("Первый logical lease должен завершиться")
        }
        let replacement = try XCTUnwrap(fixture.state.begin(scope: EventProcessingTestFixture.scope(), at: 2))
        fixture.prepared.invalidate(.stopped)
        XCTAssertNil(fixture.state.metadata.failure)
        XCTAssertFalse(fixture.prepared.publish(try fixture.publication(), at: 2))
        XCTAssertTrue(fixture.state.preCaptureReady(replacement, at: 2))
        XCTAssertEqual(fixture.recipient.bridge.snapshot.phase, "prepared")
    }

    @MainActor
    func testEvenOneUnitOfNativeDeadlineExtensionIsRejectedBeforePublication() throws {
        let fixture = try AtomicProcessingArmFixture(nativeStartAt: 1)
        XCTAssertEqual(fixture.recipient.operation.capturePort.holdDeadline, fixture.prepared.deadline + 1)
        XCTAssertFalse(fixture.prepared.matches(fixture.recipient.capture))
        XCTAssertFalse(fixture.prepared.publish(try fixture.publication(), at: 1))
        XCTAssertNil(fixture.state.metadata.failure)
        XCTAssertEqual(fixture.recipient.bridge.snapshot.phase, "prepared")
    }

    @MainActor
    func testExpiredOrForeignLeaseCannotProducePreparedToken() throws {
        let state = EventProcessingLeaseState()
        let other = EventProcessingLeaseState()
        let scope = try EventProcessingTestFixture.scope()
        let lease = try XCTUnwrap(state.begin(scope: scope, at: 0))
        let foreign = try XCTUnwrap(other.begin(scope: scope, at: 0))
        XCTAssertNil(PreparedEventProcessingArm(state: state, lease: foreign, clock: { 1 }))
        XCTAssertNil(PreparedEventProcessingArm(state: state, lease: lease, clock: { 400_000_000 }))
        XCTAssertEqual(state.metadata.failure, .expired)
        XCTAssertNil(other.metadata.failure)
    }
}
#endif
