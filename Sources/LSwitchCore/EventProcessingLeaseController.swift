import CoreGraphics
import Dispatch
import Foundation

/// Serial processingQueue → один Main блок; никакой IO/native delivery или владения held queue.
final class EventProcessingLeaseController: @unchecked Sendable {
    let state: EventProcessingLeaseState
    private let queue: DispatchQueue
    private let clock: @Sendable () -> UInt64

    init(
        state: EventProcessingLeaseState = EventProcessingLeaseState(), queue: DispatchQueue,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.state = state
        self.queue = queue
        self.clock = clock
    }

    func observe(type: CGEventType, event: CGEvent) -> Bool {
        state.observe(type: type, event: event, at: clock())
    }

    @MainActor
    func begin(scope: RecoveryOperationTarget) async -> EventProcessingLease? {
        guard let lease = state.begin(scope: scope, at: clock()) else { return nil }
        await barrier()
        queue.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            guard let self else { return }
            self.state.expire(lease, at: self.clock())
        }
        return lease
    }

    @MainActor
    func preCaptureReady(_ lease: EventProcessingLease) -> Bool { state.preCaptureReady(lease, at: clock()) }

    #if DEBUG
    @MainActor
    func prepareRecipientArm(_ lease: EventProcessingLease) -> PreparedEventProcessingArm? {
        PreparedEventProcessingArm(state: state, lease: lease, clock: clock)
    }
    #endif

    @MainActor
    func arm(_ lease: EventProcessingLease, activate: () -> Bool) -> Bool {
        guard preCaptureReady(lease) else { return false }
        guard activate() else { state.invalidate(.captureRefused, lease: lease); return false }
        return state.arm(lease, at: clock())
    }

    @MainActor
    func finish(
        _ lease: EventProcessingLease, disposition: EventProcessingDisposition, actions: EventProcessingActions
    ) async -> EventProcessingFinish {
        await withCheckedContinuation { continuation in
            queue.async {
                DispatchQueue.main.async {
                    continuation.resume(returning: self.finishOnMain(lease, disposition: disposition, actions: actions))
                }
            }
        }
    }

    @MainActor
    private func finishOnMain(
        _ lease: EventProcessingLease, disposition: EventProcessingDisposition, actions: EventProcessingActions
    ) -> EventProcessingFinish {
        guard state.claimFinish(lease, disposition: disposition, at: clock()) else { return .stale }
        actions.applyOutcome()
        while true {
            switch state.next(lease, at: clock()) {
            case .event(let raw): actions.consume(raw)
            case .finished(let result):
                if result == .stale { return .stale }
                if result != .delivered { actions.reset() }
                actions.didFinish()
                return result
            }
        }
    }

    @MainActor
    private func barrier() async {
        await withCheckedContinuation { continuation in
            queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }
}
