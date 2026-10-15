import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class EventDeliveryGateTests: XCTestCase {
    func testInitialGateDoesNotRejectEvents() {
        let gate = EventDeliveryGate()
        XCTAssertTrue(gate.accepts(timestamp: 0))
        XCTAssertTrue(gate.accepts(timestamp: UInt64.max))
    }

    func testRecoveryRejectsEarlierSnapshotsButAcceptsBoundaryAndNewInput() {
        var gate = EventDeliveryGate()
        gate.reset(at: 100)
        XCTAssertFalse(gate.accepts(timestamp: 99))
        XCTAssertTrue(gate.accepts(timestamp: 100))
        XCTAssertTrue(gate.accepts(timestamp: 101))
    }

    func testOlderResetCannotReopenStaleProcessingWindow() {
        var gate = EventDeliveryGate()
        gate.reset(at: 200)
        gate.reset(at: 100)
        XCTAssertEqual(gate.cutoff, 200)
        XCTAssertFalse(gate.accepts(timestamp: 199))
        XCTAssertTrue(gate.accepts(timestamp: 200))
    }

    @MainActor
    func testRecoveryCallbackSeesUpdatedGateBeforeResettingApplicationContext() async {
        let tap = EventTapCore { _ in XCTFail("Уведомление recovery не должно создавать событие") }
        let buffer = KeystrokeBuffer()
        buffer.append(Keystroke(kind: .character("g")))
        var callbacks: [UInt64] = []
        tap.onRecoveryStarted = { [weak tap] cutoff in
            callbacks.append(cutoff)
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(tap?.acceptsForProcessing(Self.event(timestamp: 99)), false)
            XCTAssertEqual(tap?.acceptsForProcessing(Self.event(timestamp: 100)), true)
            buffer.clear()
        }
        tap.invalidateProcessingContextForRecovery(at: 100)
        XCTAssertEqual(callbacks, [100])
        XCTAssertEqual(buffer.count, 0)
    }

    @MainActor
    func testEventAlreadyQueuedBeforeRecoveryIsRejectedAtConsumption() async {
        let tap = EventTapCore { _ in }
        let queued = Self.event(timestamp: 99)
        XCTAssertTrue(tap.acceptsForProcessing(queued))
        tap.invalidateProcessingContextForRecovery(at: 100)
        XCTAssertFalse(tap.acceptsForProcessing(queued), "Проверку необходимо повторять после перехода на main")
        XCTAssertTrue(tap.acceptsForProcessing(Self.event(timestamp: 101)))
    }

    private static func event(timestamp: UInt64) -> RawKeyEvent {
        RawKeyEvent(
            type: .keyUp, keyCode: 0x21, characters: "", modifierFlags: 0,
            isSynthetic: false, timestamp: timestamp
        )
    }
}
