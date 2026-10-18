#if DEBUG
import Dispatch
import Foundation

/// Scoped logical подготовка. Deadline получен из живого record, не задаётся consumer произвольно.
final class PreparedEventProcessingArm: @unchecked Sendable {
    let scope: RecoveryOperationTarget
    let startedAt: UInt64
    let deadline: UInt64
    private let state: EventProcessingLeaseState
    private let lease: EventProcessingLease
    private let clock: @Sendable () -> UInt64

    init?(state: EventProcessingLeaseState, lease: EventProcessingLease, clock: @escaping @Sendable () -> UInt64) {
        guard let deadline = state.preparationDeadline(lease, at: clock()),
              deadline >= EventProcessingLeaseState.duration else { return nil }
        self.state = state
        self.lease = lease
        self.deadline = deadline
        startedAt = deadline - EventProcessingLeaseState.duration
        scope = lease.scope
        self.clock = clock
    }

    var isCurrent: Bool { state.isCurrent(lease, at: clock()) }
    func currentTime() -> UInt64 { clock() }
    func invalidate(_ reason: EventProcessingInvalidation) { state.invalidate(reason, lease: lease) }

    func matches(_ capture: RecipientOrdinaryCapture) -> Bool {
        scope == capture.scope.binding.scope && capture.attachment.port.holdDeadline <= deadline
    }

    /// Clock читается вызывающим до его locks. Внутри — только конкретная локальная публикация.
    func publish(_ publication: RecipientCapturePublication, at now: UInt64) -> Bool {
        guard matches(publication.capture) else { return false }
        return state.armPublishing(lease, at: now, publication: publication)
    }
}

/// Не произвольный callback: допустимы только известные state/endpoint locks, без admission/IPC/payload.
struct RecipientCapturePublication: Sendable {
    let capture: RecipientOrdinaryCapture
    private let state: RecipientTapDriverState
    private let activation: RecoveryRecipientActivation
    private let testBarrier: RecipientPublicationTestBarrier?

    init(
        state: RecipientTapDriverState, capture: RecipientOrdinaryCapture,
        activation: RecoveryRecipientActivation, testBarrier: RecipientPublicationTestBarrier? = nil
    ) {
        self.state = state
        self.capture = capture
        self.activation = activation
        self.testBarrier = testBarrier
    }

    func publish() -> Bool {
        guard testBarrier?.wait() != false else { return false }
        return state.publishRecipientCapture(capture, activation: activation)
    }
}

/// Только внутренний memory-test seam. Настоящий RecipientCaptureArming всегда передаёт nil.
/// Ни closures, ни MainActor/IPC здесь нет; ошибочный тест ограничен ожиданием двух секунд.
final class RecipientPublicationTestBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)

    fileprivate func wait() -> Bool {
        entered.signal()
        return proceed.wait(timeout: .now() + 2) == .success
    }
}
#endif
