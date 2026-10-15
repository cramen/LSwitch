import CoreGraphics
import Foundation

/// Tap получает только этот scoped endpoint. Владелец приложения продолжает удерживать его после смерти tap.
/// Все переходы сериализованы: port → admission → buffer. Guard вызывается только после освобождения admission.
final class RecoveryCapturePort: @unchecked Sendable {
    let scope: RecoveryCaptureScope
    private let buffer: InputEventBuffer
    private let admission: PreparedRecoveryAdmission
    private let handover: PreparedRecoveryHandover
    private let lock = NSLock()
    private var stopped: RecoveryAdmissionFailure?
    private var seal: RecoveryAdmissionSeal?
    private var batch: HeldInputBatch?
    private var transferred: UUID?
    private weak var transferredCoordinator: RecoveryCoordinator?

    init(
        scope: RecoveryCaptureScope, buffer: InputEventBuffer,
        admission: PreparedRecoveryAdmission, handover: PreparedRecoveryHandover
    ) {
        self.scope = scope
        self.buffer = buffer
        self.admission = admission
        self.handover = handover
    }

    /// rejected не означает pass-through: маршрут отклонённого события обязан закрыть prearmed gate.
    func capture(
        _ event: CGEvent, utf16Units: Int, from expected: RecoveryCaptureScope, at now: UInt64
    ) -> RecoveryEventAdmission {
        lock.lock()
        defer { lock.unlock() }
        guard expected == scope else { return .rejected(.wrongBinding) }
        guard stopped == nil, seal == nil else { return .rejected(stopped ?? .closed) }
        expireLocked(at: now)
        guard stopped == nil else { return .rejected(stopped ?? .closed) }
        let result = admission.admit(utf16Units: utf16Units, binding: scope.binding) {
            buffer.intercept(type: event.type, event: event, at: now)
        }
        switch result {
        case .accepted: break
        case .acceptedRequiringHandover(let reason), .rejected(let reason): stopLocked(reason)
        }
        return result
    }

    func permitsMutation(for expected: RecoveryCaptureScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard expected == scope, stopped == nil, seal == nil, buffer.isHolding else { return false }
        guard admission.permitsMutation(for: scope.binding) else { stopLocked(.gateUnavailable); return false }
        return true
    }

    @discardableResult
    func invalidate(_ reason: RecoveryAdmissionFailure, scope expected: RecoveryCaptureScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard expected == scope else { return false }
        stopLocked(reason)
        return true
    }

    @discardableResult
    func expire(scope expected: RecoveryCaptureScope, at now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard expected == scope else { return false }
        expireLocked(at: now)
        return stopped != nil
    }

    /// Seal сам не освобождает ввод. При отказе guard очередь остаётся в том же закрытом buffer.
    func close(scope expected: RecoveryCaptureScope) -> RecoveryCaptureClosure {
        lock.lock()
        defer { lock.unlock() }
        guard expected == scope else { return .wrongScope }
        if let transferred { return .transferred(transferred) }
        stopLocked(.closed)
        if seal == nil { seal = admission.seal(binding: scope.binding) }
        guard let seal else { return .wrongScope }
        if batch == nil {
            // Здесь admission lock уже отпущен: gate → buffer, никогда gate → admission.
            handover.withProtection(for: scope) {
                if self.batch == nil { self.batch = self.buffer.detach(token: self.scope.binding.hold) }
            }
        }
        return batch == nil ? .awaitingProtection(seal.counts) : .detached(seal.counts)
    }

    /// Конкретный RAM coordinator вызывается без gate lock. Отклонение не изымает private batch.
    @MainActor
    func adopt(
        in coordinator: RecoveryCoordinator, claim: ConversionSafetyInputClaim, reason: RecoveryReason
    ) -> RecoveryOperationAdoption {
        lock.lock()
        defer { lock.unlock() }
        guard claim.operation == scope.binding.scope.operation, claim.owner == .recovery else {
            return .rejected(.wrongBinding)
        }
        if let transferred {
            guard transferredCoordinator === coordinator else { return .rejected(.wrongBinding) }
            return .adopted(transferred)
        }
        guard let seal, let batch else { return .awaitingDetach }
        switch coordinator.adopt(batch, sealed: seal, claim: claim, reason: reason) {
        case .adopted(let identifier):
            self.batch = nil
            transferred = identifier
            transferredCoordinator = coordinator
            return .adopted(identifier)
        case .rejected(let failure): return .rejected(failure)
        }
    }

    private func expireLocked(at now: UInt64) {
        buffer.expire(token: scope.binding.hold, at: now)
        if !buffer.isHolding { stopLocked(.closed) }
    }

    private func stopLocked(_ reason: RecoveryAdmissionFailure) {
        stopped = stopped ?? reason
        admission.stop(reason)
        buffer.cancelLease()
    }
}
