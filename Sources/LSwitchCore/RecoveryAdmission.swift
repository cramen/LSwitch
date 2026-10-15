import Foundation

/// Birth time предоставляет проверенный системный адаптер. Сам PID не идентифицирует экземпляр процесса.
struct RecoveryProcessIdentity: Hashable, Sendable {
    let processID: Int32
    private let birthSeconds: UInt64
    private let birthMicroseconds: UInt64

    init?(processID: Int32, birthSeconds: UInt64, birthMicroseconds: UInt64) {
        guard processID > 0, birthSeconds > 0, birthMicroseconds < 1_000_000 else { return nil }
        self.processID = processID
        self.birthSeconds = birthSeconds
        self.birthMicroseconds = birthMicroseconds
    }
}

struct RecoveryOperationTarget: Equatable, Sendable {
    let operation: ConversionSafetyOperationToken
    let target: RecoveryProcessIdentity
}

struct RecoveryHoldBinding: Equatable, Sendable {
    let scope: RecoveryOperationTarget
    let hold: InputHoldToken
}

/// Только уже подготовленная capability. Проверка обязана быть быстрой, thread-safe, без IPC и reentry.
final class RecoveryGateCapability: @unchecked Sendable {
    let scope: RecoveryOperationTarget
    private let current: @Sendable () -> Bool

    init(scope: RecoveryOperationTarget, isCurrent: @escaping @Sendable () -> Bool) {
        self.scope = scope
        self.current = isCurrent
    }

    func isCurrent(for scope: RecoveryOperationTarget) -> Bool {
        self.scope == scope && current()
    }
}

/// Реального системного prearm здесь нет; production по умолчанию отказывает.
@MainActor
struct RecoveryGateFactory {
    var prepare: (RecoveryOperationTarget) -> RecoveryGateCapability?
    static var unavailable: Self { Self(prepare: { _ in nil }) }
}

enum RecoveryAdmissionFailure: Equatable, Sendable {
    case wrongBinding, closed, gateUnavailable, invalidCost, eventLimit, payloadLimit, appendRejected
    case interceptionStopped, secureInput
}

enum RecoveryEventAdmission: Equatable, Sendable {
    case accepted
    case acceptedRequiringHandover(RecoveryAdmissionFailure)
    /// Событие не сохранено. Вызывающий gate не должен пропустить его перед удержанным префиксом.
    case rejected(RecoveryAdmissionFailure)
}

struct RecoveryAdmissionCounts: Equatable, Sendable {
    let events: Int
    let utf16Bytes: Int
}

/// Не раскрывает события; создаётся только после закрытия admission под его lock.
final class RecoveryAdmissionSeal: @unchecked Sendable {
    let binding: RecoveryHoldBinding
    let counts: RecoveryAdmissionCounts

    fileprivate init(binding: RecoveryHoldBinding, counts: RecoveryAdmissionCounts) {
        self.binding = binding
        self.counts = counts
    }
}

/// RAM reservation существует до первого удержанного события. Hold связывается без новой системной подготовки.
final class PreparedRecoveryAdmission: @unchecked Sendable {
    static let maximumEvents = 256
    static let maximumUTF16Bytes = 65_536

    let scope: RecoveryOperationTarget
    private let gate: RecoveryGateCapability
    private let lock = NSLock()
    private var binding: RecoveryHoldBinding?
    private var stopped: RecoveryAdmissionFailure?
    private var eventCount = 0
    private var byteCount = 0
    private var sealed: RecoveryAdmissionSeal?

    init(scope: RecoveryOperationTarget, gate: RecoveryGateCapability) {
        self.scope = scope
        self.gate = gate
    }

    func bindHold(_ hold: InputHoldToken) -> RecoveryHoldBinding? {
        lock.lock()
        defer { lock.unlock() }
        guard binding == nil, stopped == nil else { return nil }
        guard gate.isCurrent(for: scope) else { stopped = .gateUnavailable; return nil }
        let bound = RecoveryHoldBinding(scope: scope, hold: hold)
        binding = bound
        return bound
    }

    func permitsMutation(for expected: RecoveryHoldBinding) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard binding == expected, stopped == nil else { return false }
        guard gate.isCurrent(for: scope) else { stopped = .gateUnavailable; return false }
        return true
    }

    /// Размер измеряет capture-адаптер до append. Это логические UTF-16 units, не RSS CGEvent.
    /// Lock order: admission → внутренний RAM append. Closure не вызывает admission повторно и не делает IO.
    /// false от append означает отсутствие изменений очереди; частичный append с false запрещён контрактом.
    func admit(
        utf16Units: Int, binding expected: RecoveryHoldBinding, append: () -> Bool
    ) -> RecoveryEventAdmission {
        lock.lock()
        defer { lock.unlock() }
        guard binding == expected else { return .rejected(.wrongBinding) }
        guard stopped == nil else { return .rejected(stopped ?? .closed) }
        if let failure = admissionFailure(utf16Units: utf16Units) { return rejectAndStop(failure) }
        guard append() else { return rejectAndStop(.appendRejected) }
        eventCount += 1
        byteCount += utf16Units * 2
        if let reason = handoverReason() {
            stopped = reason
            return .acceptedRequiringHandover(reason)
        }
        return .accepted
    }

    func stop(_ reason: RecoveryAdmissionFailure) {
        lock.lock()
        defer { lock.unlock() }
        if stopped == nil { stopped = reason }
    }

    /// Seal ждёт завершения уже допущенного append; после него старую запись нельзя расширить.
    func seal(binding expected: RecoveryHoldBinding) -> RecoveryAdmissionSeal? {
        lock.lock()
        defer { lock.unlock() }
        guard binding == expected else { return nil }
        if let sealed { return sealed }
        let result = RecoveryAdmissionSeal(
            binding: expected, counts: RecoveryAdmissionCounts(events: eventCount, utf16Bytes: byteCount)
        )
        stopped = stopped ?? .closed
        sealed = result
        return result
    }

    func owns(_ seal: RecoveryAdmissionSeal) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sealed === seal
    }

    func abandonBeforeHold() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard binding == nil, eventCount == 0 else { return false }
        stopped = .closed
        return true
    }

    private func rejectAndStop(_ reason: RecoveryAdmissionFailure) -> RecoveryEventAdmission {
        stopped = reason
        return .rejected(reason)
    }

    /// Helpers вызываются только под lock; арифметика выполняется после проверки остатка квоты.
    private func admissionFailure(utf16Units: Int) -> RecoveryAdmissionFailure? {
        guard gate.isCurrent(for: scope) else { return .gateUnavailable }
        guard utf16Units >= 0 else { return .invalidCost }
        guard eventCount < Self.maximumEvents else { return .eventLimit }
        return utf16Units <= (Self.maximumUTF16Bytes - byteCount) / 2 ? nil : .payloadLimit
    }

    private func handoverReason() -> RecoveryAdmissionFailure? {
        if !gate.isCurrent(for: scope) { return .gateUnavailable }
        if eventCount == Self.maximumEvents { return .eventLimit }
        return byteCount == Self.maximumUTF16Bytes ? .payloadLimit : nil
    }
}
