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

    func testDetachPreservesOrderAndPreventsLegacyEndReplay() throws {
        let buffer = InputEventBuffer()
        let token = try XCTUnwrap(buffer.beginHold(at: 0))
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .leftMouseUp]
        for (index, type) in types.enumerated() {
            let input = try event(type, timestamp: UInt64(index + 1), marker: Int64(index + 40))
            XCTAssertTrue(buffer.intercept(type: type, event: input, at: 20))
        }
        let batch = try XCTUnwrap(buffer.detach(token: token))
        XCTAssertEqual(batch.token, token)
        XCTAssertEqual(batch.generation, token.generation)
        XCTAssertEqual(batch.eventCount, types.count)
        XCTAssertFalse(buffer.isActive)
        XCTAssertFalse(buffer.isHolding)
        XCTAssertNil(buffer.detach(token: token))
        buffer.end { _ in XCTFail("Переданные события не должны попасть в legacy end") }
        XCTAssertFalse(buffer.intercept(type: .keyDown, event: try event(), at: 21))
        let claimed = try XCTUnwrap(batch.claim())
        XCTAssertEqual(claimed.map(\.type), types)
        XCTAssertEqual(claimed.map(\.timestamp), [1, 2, 3, 4, 5])
        XCTAssertEqual(claimed.map { $0.getIntegerValueField(.eventSourceUserData) }, [40, 41, 42, 43, 44])
        XCTAssertNil(batch.claim())
    }

    func testDetachKeepsIndependentCopiesOfRepeatedInputObject() throws {
        let buffer = InputEventBuffer()
        let token = try XCTUnwrap(buffer.beginHold(at: 0))
        let input = try event(key: 13, marker: 42)
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: input, at: 1))
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: input, at: 2))
        input.setIntegerValueField(.keyboardEventKeycode, value: 12)
        let batch = try XCTUnwrap(buffer.detach(token: token))
        input.setIntegerValueField(.eventSourceUserData, value: 43)
        let claimed = try XCTUnwrap(batch.claim())
        XCTAssertEqual(claimed.count, 2)
        guard claimed.count == 2 else { return }
        XCTAssertEqual(claimed[0].getIntegerValueField(.keyboardEventKeycode), 13)
        XCTAssertEqual(claimed[0].getIntegerValueField(.eventSourceUserData), 42)
        claimed[0].setIntegerValueField(.keyboardEventKeycode, value: 9)
        XCTAssertEqual(claimed[1].getIntegerValueField(.keyboardEventKeycode), 13)
        XCTAssertEqual(input.getIntegerValueField(.keyboardEventKeycode), 12)
    }

    func testStaleDetachAndTimerCannotTakeOrExpireNextGeneration() throws {
        let buffer = InputEventBuffer()
        let first = try XCTUnwrap(buffer.beginHold(at: 0))
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: try event(marker: 41), at: 1))
        let firstBatch = try XCTUnwrap(buffer.detach(token: first))
        let second = try XCTUnwrap(buffer.beginHold(at: 20))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(buffer.intercept(type: .keyUp, event: try event(.keyUp, marker: 42), at: 21))
        buffer.expire(generation: first.generation, at: InputEventBuffer.maximumDuration + 20)
        XCTAssertNil(buffer.detach(token: first))
        XCTAssertTrue(buffer.isHolding)
        let secondBatch = try XCTUnwrap(buffer.detach(token: second))
        XCTAssertEqual(try XCTUnwrap(firstBatch.claim()).map(\.type), [.keyDown])
        XCTAssertEqual(try XCTUnwrap(secondBatch.claim()).map(\.type), [.keyUp])
        XCTAssertNil(buffer.detach(token: second))
    }

    func testLateScopedEndCannotReleaseNewHold() throws {
        let buffer = InputEventBuffer()
        let first = try XCTUnwrap(buffer.beginHold(at: 0))
        let detached = try XCTUnwrap(buffer.detach(token: first))
        let second = try XCTUnwrap(buffer.beginHold(at: 20))
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: try event(marker: 42), at: 21))
        XCTAssertFalse(buffer.end(token: first) { _ in XCTFail("Старый end не владеет новой очередью") })
        XCTAssertTrue(buffer.isHolding)
        var delivered: [CGEventType] = []
        XCTAssertTrue(buffer.end(token: second) { delivered.append($0.type) })
        XCTAssertEqual(delivered, [.keyDown])
        XCTAssertFalse(buffer.isActive)
        XCTAssertFalse(buffer.end(token: second) { _ in XCTFail("Поколение уже завершено") })
        XCTAssertTrue(try XCTUnwrap(detached.claim()).isEmpty)
    }
}

extension InputEventBufferTests {
    func testForeignTokenCannotDetachReleaseOrExpireEqualGeneration() throws {
        let first = InputEventBuffer()
        let second = InputEventBuffer()
        let firstToken = try XCTUnwrap(first.beginHold(at: 0))
        let secondToken = try XCTUnwrap(second.beginHold(at: 0))
        XCTAssertEqual(firstToken.generation, secondToken.generation)
        XCTAssertNotEqual(firstToken, secondToken)
        XCTAssertTrue(first.intercept(type: .keyDown, event: try event(marker: 41), at: 1))
        XCTAssertTrue(second.intercept(type: .keyUp, event: try event(.keyUp, marker: 42), at: 1))

        XCTAssertNil(first.detach(token: secondToken))
        XCTAssertFalse(first.end(token: secondToken) { _ in XCTFail("Чужой token не разрешает доставку") })
        first.expire(token: secondToken, at: InputEventBuffer.maximumDuration)
        XCTAssertTrue(first.isHolding)
        XCTAssertNil(second.detach(token: firstToken))
        XCTAssertFalse(second.end(token: firstToken) { _ in XCTFail("Чужой token не владеет второй очередью") })
        XCTAssertTrue(second.isHolding)

        let batch = try XCTUnwrap(first.detach(token: firstToken))
        XCTAssertEqual(batch.token, firstToken)
        XCTAssertEqual(try XCTUnwrap(batch.claim()).map(\.type), [.keyDown])
        var delivered: [CGEventType] = []
        XCTAssertTrue(second.end(token: secondToken) { delivered.append($0.type) })
        XCTAssertEqual(delivered, [.keyUp])
        XCTAssertNil(first.detach(token: firstToken))
        XCTAssertFalse(second.end(token: secondToken) { _ in XCTFail("Повторная доставка запрещена") })
    }

    func testStaleTokenCannotTakeReleaseOrExpireNextHold() throws {
        let buffer = InputEventBuffer()
        let old = try XCTUnwrap(buffer.beginHold(at: 0))
        XCTAssertNil(buffer.beginHold(at: 1))
        XCTAssertNil(buffer.begin(at: 1))
        let empty = try XCTUnwrap(buffer.detach(token: old))
        let current = try XCTUnwrap(buffer.beginHold(at: 20))
        XCTAssertNotEqual(old.generation, current.generation)
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: try event(), at: 21))
        XCTAssertNil(buffer.detach(token: old))
        XCTAssertFalse(buffer.end(token: old) { _ in XCTFail("Старый token не выпускает новый hold") })
        buffer.expire(token: old, at: InputEventBuffer.maximumDuration + 20)
        XCTAssertTrue(buffer.isHolding)
        buffer.expire(token: current, at: InputEventBuffer.maximumDuration + 20)
        XCTAssertFalse(buffer.isHolding)
        let batch = try XCTUnwrap(buffer.detach(token: current))
        XCTAssertEqual(batch.token, current)
        XCTAssertEqual(try XCTUnwrap(batch.claim()).map(\.type), [.keyDown])
        XCTAssertEqual(empty.token, old)
        XCTAssertTrue(try XCTUnwrap(empty.claim()).isEmpty)
        XCTAssertNil(buffer.detach(token: current))
    }
}
