import CoreGraphics
@testable import LSwitchCore
import XCTest

final class InputEventBufferTests: XCTestCase {
    private func event(
        _ type: CGEventType = .keyDown, key: CGKeyCode = 0, timestamp: UInt64 = 10, marker: Int64 = 0
    ) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: type == .keyDown))
        event.type = type
        event.timestamp = timestamp
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    func testEndPreservesOrderAndForeignMetadataExactlyOnce() throws {
        let buffer = InputEventBuffer()
        XCTAssertNotNil(buffer.begin(at: 0))
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        for (index, type) in types.enumerated() {
            let input = try event(type, timestamp: UInt64(index + 1), marker: Int64(index + 40))
            XCTAssertTrue(buffer.intercept(type: type, event: input, at: 20))
        }
        var delivered: [CGEvent] = []
        buffer.end { delivered.append($0) }
        XCTAssertEqual(delivered.map(\.type), types)
        XCTAssertEqual(delivered.map { $0.getIntegerValueField(.eventSourceUserData) }, [40, 41, 42, 43, 44])
        XCTAssertTrue(delivered.allSatisfy { !SyntheticEventMarker.isSynthetic($0) })
        buffer.end { _ in XCTFail("Повторный end не должен доставить события снова") }
        XCTAssertFalse(buffer.isActive)
        XCTAssertFalse(buffer.isHolding)
    }

    func testSyntheticAndUnrelatedEventsAreNeverHeld() throws {
        let buffer = InputEventBuffer()
        XCTAssertNotNil(buffer.begin(at: 0))
        let synthetic = try event()
        XCTAssertTrue(SyntheticEventMarker.tag(synthetic))
        XCTAssertEqual(synthetic.getIntegerValueField(.eventSourceUserData), SyntheticEventMarker.magic)
        XCTAssertTrue(SyntheticEventMarker.isSynthetic(synthetic))
        XCTAssertFalse(buffer.intercept(type: .keyDown, event: synthetic, at: 10))
        for type: CGEventType in [.mouseMoved, .scrollWheel, .null] {
            XCTAssertFalse(buffer.intercept(type: type, event: try event(type), at: 10))
        }
        buffer.end { _ in XCTFail("Собственная синтетика не должна попадать в очередь") }
    }

    func testAllKeyboardAndMouseGestureEventsAreHeld() throws {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged
        ]
        let buffer = InputEventBuffer()
        XCTAssertNotNil(buffer.begin(at: 0))
        for type in types { XCTAssertTrue(buffer.intercept(type: type, event: try event(type), at: 10)) }
        var delivered: [CGEventType] = []
        buffer.end { delivered.append($0.type) }
        XCTAssertEqual(delivered, types)
    }

    func testHeldEventIsIndependentCopy() throws {
        let buffer = InputEventBuffer()
        XCTAssertNotNil(buffer.begin(at: 0))
        let input = try event(key: 13, marker: 42)
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: input, at: 10))
        input.setIntegerValueField(.keyboardEventKeycode, value: 12)
        buffer.end {
            XCTAssertEqual($0.getIntegerValueField(.keyboardEventKeycode), 13)
            XCTAssertEqual($0.getIntegerValueField(.eventSourceUserData), 42)
        }
    }

    func testTimeoutCancelsLeaseButHoldsDownAndUpUntilCleanupEnds() throws {
        let buffer = InputEventBuffer()
        let generation = try XCTUnwrap(buffer.begin(at: 0))
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: try event(), at: 10))
        buffer.expire(generation: generation, at: InputEventBuffer.maximumDuration - 1)
        XCTAssertTrue(buffer.isHolding)
        buffer.expire(generation: generation, at: InputEventBuffer.maximumDuration)
        XCTAssertFalse(buffer.isHolding)
        XCTAssertTrue(buffer.isActive)
        XCTAssertNil(buffer.begin(at: InputEventBuffer.maximumDuration + 1))
        XCTAssertTrue(buffer.intercept(
            type: .keyUp, event: try event(.keyUp), at: InputEventBuffer.maximumDuration + 1
        ))
        var delivered: [CGEventType] = []
        buffer.end { delivered.append($0.type) }
        XCTAssertEqual(delivered, [.keyDown, .keyUp])
        XCTAssertFalse(buffer.intercept(type: .keyDown, event: try event(), at: InputEventBuffer.maximumDuration + 2))
    }

    func testCallbackEnforcesTimeoutEvenBeforeTimerRuns() throws {
        let buffer = InputEventBuffer()
        XCTAssertNotNil(buffer.begin(at: 0))
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: try event(), at: InputEventBuffer.maximumDuration))
        XCTAssertFalse(buffer.isHolding)
        XCTAssertTrue(buffer.isActive)
        var count = 0
        buffer.end { _ in count += 1 }
        XCTAssertEqual(count, 1)
    }

    func testOldTimerCannotCancelNewHold() throws {
        let buffer = InputEventBuffer()
        let first = try XCTUnwrap(buffer.begin(at: 0))
        buffer.end { _ in XCTFail("Очередь пуста") }
        let second = try XCTUnwrap(buffer.begin(at: 20))
        buffer.expire(generation: first, at: InputEventBuffer.maximumDuration + 20)
        XCTAssertTrue(buffer.isHolding)
        buffer.expire(generation: second, at: InputEventBuffer.maximumDuration + 20)
        XCTAssertFalse(buffer.isHolding)
    }

    func testCountBudgetCancelsWithoutReleasingOrLosingFollowingKeyUp() throws {
        let buffer = InputEventBuffer()
        XCTAssertNotNil(buffer.begin(at: 0))
        for index in 0..<InputEventBuffer.maximumCount {
            XCTAssertTrue(buffer.intercept(
                type: .keyDown, event: try event(timestamp: UInt64(index)), at: UInt64(index)
            ))
        }
        XCTAssertFalse(buffer.isHolding)
        XCTAssertTrue(buffer.isActive)
        XCTAssertTrue(buffer.intercept(type: .keyUp, event: try event(.keyUp, timestamp: 999), at: 999))
        var delivered: [CGEvent] = []
        buffer.end { delivered.append($0) }
        XCTAssertEqual(delivered.count, InputEventBuffer.maximumCount + 1)
        XCTAssertEqual(delivered.dropLast().map(\.timestamp), (0..<InputEventBuffer.maximumCount).map(UInt64.init))
        XCTAssertEqual(delivered.last?.type, .keyUp)
    }

    func testStopOrRecoveryCancellationKeepsInputUntilExplicitEnd() throws {
        let buffer = InputEventBuffer()
        XCTAssertNotNil(buffer.begin(at: 0))
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: try event(marker: 41), at: 1))
        buffer.cancelLease()
        XCTAssertFalse(buffer.isHolding)
        XCTAssertTrue(buffer.isActive)
        XCTAssertTrue(buffer.intercept(type: .keyUp, event: try event(.keyUp, marker: 42), at: 2))
        var delivered: [CGEvent] = []
        buffer.end { delivered.append($0) }
        XCTAssertEqual(delivered.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(delivered.map { $0.getIntegerValueField(.eventSourceUserData) }, [41, 42])
        buffer.end { _ in XCTFail("Нельзя повторно выпустить ввод при stop/deinit") }
    }

    func testEndNeedsNoReplayAcknowledgementBeforeNextHold() throws {
        let buffer = InputEventBuffer()
        XCTAssertNotNil(buffer.begin(at: 0))
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: try event(), at: 1))
        var delivered = 0
        buffer.end { _ in delivered += 1 }
        XCTAssertEqual(delivered, 1)
        XCTAssertNotNil(buffer.begin(at: 2))
        XCTAssertNil(buffer.begin(at: 3))
    }
}
