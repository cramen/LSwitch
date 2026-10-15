import CoreGraphics
import Dispatch
@testable import LSwitchCore
import XCTest

final class PendingInputDrainTests: XCTestCase {
    @MainActor
    func testPreHoldRawCallbackInvalidatesRevisionBeforeAnyEngineRuns() async {
        let queue = DispatchQueue(label: "lswitch.tests.prehold")
        let tap = EventTapCore(handler: { _ in }, processingQueue: queue)
        let fixture = ConverterFixture()
        fixture.succeed(fixture.axEngine)
        let converter = fixture.converter
        queue.suspend()
        queue.async {
            DispatchQueue.main.async {
                XCTAssertTrue(fixture.holdActive)
                fixture.actions.append("pre-hold-raw")
                converter.notifyOtherKeystroke()
            }
        }
        fixture.drainHandler = {
            queue.resume()
            await tap.drainPendingEvents()
        }
        let outcome = await converter.trigger(expectedWord: "ghbdtn", allowUndo: false)
        XCTAssertEqual(outcome, .blockedBySafety)
        XCTAssertEqual(fixture.actions, ["hold", "pre-hold-raw", "release"])
        XCTAssertTrue(fixture.axEngine.requests.isEmpty)
        XCTAssertTrue(fixture.clipboardEngine.requests.isEmpty)
        XCTAssertFalse(fixture.holdActive)
    }

    @MainActor
    func testHeldEventIsNotDeliveredByQueueDrainBeforeExplicitRelease() async throws {
        let queue = DispatchQueue(label: "lswitch.tests.held")
        let tap = EventTapCore(handler: { _ in }, processingQueue: queue)
        let buffer = InputEventBuffer()
        let input = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        let counter = PendingInputCounter()
        XCTAssertNotNil(buffer.begin(at: 0))
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: input, at: 1))
        await tap.drainPendingEvents()
        XCTAssertEqual(counter.deliveries, 0)
        XCTAssertTrue(buffer.isHolding)
        buffer.end { _ in
            queue.async { DispatchQueue.main.async { counter.deliveries += 1 } }
        }
        await tap.drainPendingEvents()
        XCTAssertEqual(counter.deliveries, 1)
        XCTAssertFalse(buffer.isHolding)
    }

    @MainActor
    func testLeaseExpiryWhileDrainingDoesNotReachEngine() async {
        let fixture = ConverterFixture()
        fixture.drainHandler = { fixture.holdActive = false }
        let outcome = await fixture.converter.trigger(expectedWord: "ghbdtn", allowUndo: false)
        XCTAssertEqual(outcome, .blockedBySafety)
        XCTAssertEqual(fixture.actions, ["hold", "release"])
        XCTAssertTrue(fixture.axEngine.requests.isEmpty)
    }
}

@MainActor
private final class PendingInputCounter {
    var deliveries = 0
}
