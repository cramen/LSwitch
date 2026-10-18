#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class AtomicArmResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?
    func set(_ result: Bool) { lock.lock(); value = result; lock.unlock() }
    func read() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class AtomicProcessingArmFixture {
    let recipient: RecipientOrdinaryFixture
    let state = EventProcessingLeaseState()
    let lease: EventProcessingLease
    let prepared: PreparedEventProcessingArm
    let clock = EventProcessingTestClock()

    init(beginAt: UInt64 = 0, nativeStartAt: UInt64 = 0) throws {
        let recipient = try RecipientOrdinaryFixture(arm: false, deadline: 400_000_000, startedAt: nativeStartAt)
        self.recipient = recipient
        let scope = recipient.capture.scope.binding.scope
        lease = try XCTUnwrap(state.begin(scope: scope, at: beginAt))
        clock.advance(to: beginAt)
        let clock = self.clock
        prepared = try XCTUnwrap(PreparedEventProcessingArm(state: state, lease: lease, clock: { clock.read() }))
    }

    func publication(barrier: RecipientPublicationTestBarrier? = nil) throws -> RecipientCapturePublication {
        .init(state: recipient.state, capture: recipient.capture,
              activation: try XCTUnwrap(recipient.bridge.prepareActivation()), testBarrier: barrier)
    }

    func request() throws -> RecipientCaptureArming {
        .init(state: recipient.state, capture: recipient.capture,
              activation: try XCTUnwrap(recipient.bridge.prepareActivation()), processingArm: prepared)
    }
}
#endif
