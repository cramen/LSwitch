import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class HeldInputBatchTests: XCTestCase {
    private func event(_ type: CGEventType = .keyDown) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: type == .keyDown))
        event.type = type
        return event
    }

    func testActiveEmptyBatchIsClaimableOnceAndInactiveBufferCannotDetach() throws {
        let buffer = InputEventBuffer()
        let token = try XCTUnwrap(buffer.beginHold(at: 0))
        let batch = try XCTUnwrap(buffer.detach(token: token))
        XCTAssertEqual(batch.eventCount, 0)
        XCTAssertTrue(try XCTUnwrap(batch.claim()).isEmpty)
        XCTAssertNil(batch.claim())
        XCTAssertNil(buffer.detach(token: token))
    }

    func testCancelledAndExpiredLeaseStillTransfersPartialPairs() throws {
        for cancelled in [false, true] {
            let buffer = InputEventBuffer()
            let token = try XCTUnwrap(buffer.beginHold(at: 0))
            XCTAssertTrue(buffer.intercept(type: .flagsChanged, event: try event(.flagsChanged), at: 1))
            XCTAssertTrue(buffer.intercept(type: .keyDown, event: try event(), at: 2))
            if cancelled {
                buffer.cancelLease()
            } else {
                buffer.expire(token: token, at: InputEventBuffer.maximumDuration)
            }
            XCTAssertFalse(buffer.isHolding)
            let batch = try XCTUnwrap(buffer.detach(token: token))
            XCTAssertEqual(try XCTUnwrap(batch.claim()).map(\.type), [.flagsChanged, .keyDown])
            buffer.end { _ in XCTFail("Detach не должен синтезировать балансировку или replay") }
        }
    }

    func testTransferredBatchOutlivesSourceBuffer() throws {
        var buffer: InputEventBuffer? = InputEventBuffer()
        let token = try XCTUnwrap(buffer?.beginHold(at: 0))
        XCTAssertEqual(buffer?.intercept(type: .keyUp, event: try event(.keyUp), at: 1), true)
        let batch = try XCTUnwrap(buffer?.detach(token: token))
        buffer = nil
        let replacement = InputEventBuffer()
        let replacementToken = try XCTUnwrap(replacement.beginHold(at: 0))
        XCTAssertEqual(replacementToken.generation, token.generation)
        XCTAssertNotEqual(replacementToken, batch.token)
        XCTAssertNil(replacement.detach(token: batch.token))
        XCTAssertTrue(replacement.isHolding)
        XCTAssertNotNil(replacement.detach(token: replacementToken))
        XCTAssertEqual(try XCTUnwrap(batch.claim()).map(\.type), [.keyUp])
        XCTAssertNil(batch.claim())
    }

    func testConcurrentClaimHasExactlyOneOwner() throws {
        let buffer = InputEventBuffer()
        let token = try XCTUnwrap(buffer.beginHold(at: 0))
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: try event(), at: 1))
        let batch = try XCTUnwrap(buffer.detach(token: token))
        let result = ClaimCounts()
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if let claimed = batch.claim() { result.recordClaim(eventCount: claimed.count) }
        }
        XCTAssertEqual(result.claims, 1)
        XCTAssertEqual(result.events, 1)
        XCTAssertNil(batch.claim())
    }

    func testDetachAndLegacyEndCompeteForSingleWholeQueue() throws {
        let buffer = InputEventBuffer()
        let token = try XCTUnwrap(buffer.beginHold(at: 0))
        for _ in 0..<3 { XCTAssertTrue(buffer.intercept(type: .keyDown, event: try event(), at: 1)) }
        let result = ClaimCounts()
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            if index == 0 {
                if let claimed = buffer.detach(token: token)?.claim() {
                    result.recordClaim(eventCount: claimed.count)
                }
            } else {
                buffer.end { _ in result.recordLegacyDelivery() }
            }
        }
        XCTAssertTrue((result.claims == 1 && result.events == 3) || (result.claims == 0 && result.events == 0))
        XCTAssertEqual(result.events + result.legacyDeliveries, 3)
        XCTAssertNil(buffer.detach(token: token))
        buffer.end { _ in XCTFail("Оба пути уже завершены; повторная доставка запрещена") }
    }
}

/// Только счётчики результата гонки, без ссылок на payload.
private final class ClaimCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var storedClaims = 0
    private var storedEvents = 0
    private var storedLegacyDeliveries = 0

    var claims: Int { read { storedClaims } }
    var events: Int { read { storedEvents } }
    var legacyDeliveries: Int { read { storedLegacyDeliveries } }

    func recordClaim(eventCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        storedClaims += 1
        storedEvents += eventCount
    }

    func recordLegacyDelivery() {
        lock.lock()
        defer { lock.unlock() }
        storedLegacyDeliveries += 1
    }

    private func read(_ value: () -> Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value()
    }
}
