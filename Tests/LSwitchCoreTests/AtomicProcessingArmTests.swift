#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class AtomicProcessingArmTests: XCTestCase {
    @MainActor
    func testGlobalCallbackWaitsForNativePublicationThenBothTailsCaptureExactlyOnce() throws {
        let fixture = try AtomicProcessingArmFixture()
        let barrier = RecipientPublicationTestBarrier()
        let publication = try fixture.publication(barrier: barrier)
        let prepared = fixture.prepared
        let logical = fixture.state
        let native = fixture.recipient.state
        let result = AtomicArmResult()
        let worker = DispatchQueue(label: "AtomicProcessingArmTests.worker")
        let armed = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let logicalFinished = DispatchSemaphore(value: 0)
        let nativeFinished = DispatchSemaphore(value: 0)
        let event = try EventProcessingTestFixture.event("kept")
        worker.async { result.set(prepared.publish(publication, at: 1)); armed.signal() }
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 1), .success)
        Thread {
            entered.signal()
            XCTAssertTrue(logical.observe(type: .keyDown, event: event, at: 2))
            logicalFinished.signal()
            worker.async {
                XCTAssertFalse(native.observe(type: .keyDown, event: event, isHead: true))
                nativeFinished.signal()
            }
        }.start()
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(logicalFinished.wait(timeout: .now() + .milliseconds(20)), .timedOut)
        barrier.proceed.signal()
        XCTAssertEqual(armed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(logicalFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(nativeFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(result.read(), true)
        XCTAssertEqual(logical.metadata.eventCount, 1)
        XCTAssertEqual(logical.metadata.payloadReads, 1)
        XCTAssertEqual(fixture.recipient.attachment.counters.capturedEvents, 1)
        XCTAssertEqual(fixture.recipient.attachment.counters.payloadCountReads, 1)
    }

    @MainActor
    func testInputBeforeWorkerArmRefusesNativePublicationWithoutReadingPayload() throws {
        let fixture = try AtomicProcessingArmFixture()
        XCTAssertTrue(fixture.state.observe(type: .keyDown, event: try EventProcessingTestFixture.event(), at: 1))
        XCTAssertFalse(fixture.prepared.publish(try fixture.publication(), at: 2))
        XCTAssertEqual(fixture.state.metadata.failure, .inputBeforeCapture)
        XCTAssertEqual(fixture.state.metadata.payloadReads, 0)
        XCTAssertEqual(fixture.recipient.bridge.snapshot.phase, "prepared")
        XCTAssertFalse(fixture.recipient.capture.isCurrent)
        XCTAssertEqual(fixture.recipient.attachment.counters.payloadCountReads, 0)
    }

    @MainActor
    func testNativePrearmRefusalInvalidatesLogicalLeaseWithoutAllowingLaterPayloadReads() throws {
        let fixture = try AtomicProcessingArmFixture()
        fixture.recipient.state.recordPhysicalButtons(released: false)
        XCTAssertFalse(fixture.prepared.publish(try fixture.publication(), at: 1))
        XCTAssertEqual(fixture.state.metadata.failure, .captureRefused)
        XCTAssertTrue(fixture.state.observe(type: .keyDown, event: try EventProcessingTestFixture.event(), at: 2))
        XCTAssertEqual(fixture.state.metadata.payloadReads, 0)
        XCTAssertFalse(fixture.prepared.isCurrent)
        XCTAssertEqual(fixture.recipient.bridge.snapshot.phase, "prepared")
    }

    @MainActor
    func testPreparedTokenUsesActualDeadlineAndCannotExtendNativeHold() throws {
        let fixture = try AtomicProcessingArmFixture()
        XCTAssertEqual(fixture.prepared.startedAt, 0)
        XCTAssertEqual(fixture.prepared.deadline, 400_000_000)
        XCTAssertEqual(fixture.prepared.deadline, fixture.recipient.operation.capturePort.holdDeadline)
        fixture.clock.advance(to: 400_000_000)
        XCTAssertFalse(fixture.prepared.publish(try fixture.publication(), at: fixture.prepared.currentTime()))
        XCTAssertEqual(fixture.state.metadata.failure, .expired)
        XCTAssertEqual(fixture.recipient.bridge.snapshot.phase, "prepared")
    }

    @MainActor
    func testForeignScopeCannotPublishOrInvalidateAnotherPreparedLease() throws {
        let first = try AtomicProcessingArmFixture()
        let second = try AtomicProcessingArmFixture()
        XCTAssertFalse(first.prepared.matches(second.recipient.capture))
        XCTAssertFalse(first.prepared.publish(try second.publication(), at: 1))
        XCTAssertNil(first.state.metadata.failure)
        XCTAssertNil(second.state.metadata.failure)
        XCTAssertEqual(second.recipient.bridge.snapshot.phase, "prepared")
        XCTAssertTrue(first.prepared.publish(try first.publication(), at: 1))
    }
}
#endif
