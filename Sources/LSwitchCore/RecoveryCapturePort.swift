import CoreGraphics
import Foundation

/// Tap получает только этот scoped endpoint. Владелец приложения продолжает удерживать его после смерти tap.
/// Все переходы сериализованы: port → admission → buffer. Guard вызывается только после освобождения admission.
final class RecoveryCapturePort: @unchecked Sendable {
    let scope: RecoveryCaptureScope
    let holdDeadline: UInt64
    private let buffer: InputEventBuffer
    private let admission: PreparedRecoveryAdmission
    private let handover: PreparedRecoveryHandover
    private let lock = NSLock()
    private var stopped: RecoveryAdmissionFailure?
    private var seal: RecoveryAdmissionSeal?
    private var batch: HeldInputBatch?
    private var transferred: UUID?
    private weak var transferredCoordinator: RecoveryCoordinator?
    private var ordinaryCustody: OrdinaryInputCustody?

    init(
        scope: RecoveryCaptureScope, buffer: InputEventBuffer,
        admission: PreparedRecoveryAdmission, handover: PreparedRecoveryHandover, holdDeadline: UInt64
    ) {
        self.scope = scope
        self.holdDeadline = holdDeadline
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
            buffer.captureAuthorized(event, at: now)
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

    /// Не ждёт callback, удерживающий port. Pending сохраняет прежнего владельца и не открывает маршрут.
    func trySealForStorage(scope expected: RecoveryCaptureScope) -> RecoveryAdmissionSeal? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        guard expected == scope, transferred == nil else { return nil }
        stopLocked(.interceptionStopped)
        if seal == nil { seal = admission.seal(binding: scope.binding) }
        return seal
    }

    func ownsStorageSeal(_ expected: RecoveryAdmissionSeal) -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        return stopped != nil && transferred == nil && seal === expected
    }

    /// Только локальное RAM-владение. Gate, post и ledger здесь вообще не вызываются.
    func detachForStorage(proof: RecoveryRetiredCaptureProof) -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        guard stopped != nil, transferred == nil, let seal,
              proof.consume(scope: scope, seal: seal) else { return false }
        if batch == nil { batch = buffer.detach(token: scope.binding.hold) }
        return batch != nil
    }

    /// Quiescence разрешает только передачу RAM. Native flush и его route permit остаются у transport.
    func takeOrdinary(
        claim: ConversionSafetyInputClaim, quiescence: RecoveryRetiredCaptureProof
    ) -> OrdinaryInputCustody? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        guard stopped != nil, transferred == nil, ordinaryCustody == nil, let seal,
              claim.operation == scope.binding.scope.operation, claim.owner == .ordinaryDelivery,
              quiescence.consume(scope: scope, seal: seal) else { return nil }
        if batch == nil { batch = buffer.detach(token: scope.binding.hold) }
        guard let batch else { return nil }
        let transfer = OrdinaryCaptureTransfer(scope: scope, seal: seal, claim: claim, batch: batch)
        guard let custody = OrdinaryInputCustody.take(transfer) else { return nil }
        self.batch = nil
        ordinaryCustody = custody
        transferred = custody.identifier
        return custody
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

/// Создаётся только этим port после quiescence. Не является вторым ledger claim.
final class OrdinaryCaptureTransfer {
    let scope: RecoveryCaptureScope
    let seal: RecoveryAdmissionSeal
    let claim: ConversionSafetyInputClaim
    private let batch: HeldInputBatch
    var token: InputHoldToken { batch.token }
    var eventCount: Int { batch.eventCount }

    fileprivate init(
        scope: RecoveryCaptureScope, seal: RecoveryAdmissionSeal,
        claim: ConversionSafetyInputClaim, batch: HeldInputBatch
    ) {
        self.scope = scope
        self.seal = seal
        self.claim = claim
        self.batch = batch
    }

    func takeEvents() -> [CGEvent]? { batch.claim() }
}
