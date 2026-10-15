import CoreGraphics
import Foundation

enum RecoveryReason: Equatable, Sendable { case cleanupUnconfirmed, admissionStopped, gateLost, interceptionStopped }
enum RecoveryProtectionStatus: Equatable, Sendable { case unverified, unavailable, interceptionOff }
enum RecoveryAdoptionFailure: Equatable, Sendable { case noReservation, wrongBinding, countMismatch, alreadyClaimed }
enum RecoveryAdoptionResult: Equatable, Sendable { case adopted(UUID), rejected(RecoveryAdoptionFailure) }

/// Только сведения для закрытого UI; ни событие, ни текст, ни произвольная строка причины сюда не входят.
struct RecoveryMetadata: Equatable, Sendable {
    let identifier: UUID
    let binding: RecoveryHoldBinding
    let reason: RecoveryReason
    let eventCount: Int
    let utf16Bytes: Int
    let payloadDeleted: Bool
    let isVisible: Bool
    let protection: RecoveryProtectionStatus
}

struct RecoveryUserIntent: Equatable, Sendable {
    fileprivate enum Purpose { case deletePayload, quit }
    fileprivate let identifier = UUID()
    fileprivate let record: UUID
    fileprivate let purpose: Purpose
}

enum RecoveryQuitRequest: Equatable, Sendable {
    case allowed, handoverRequired, confirmationRequired(RecoveryUserIntent)
}
enum RecoveryQuitChoice: Sendable { case stay, deleteAndQuit }
enum RecoveryUserDecisionResult: Equatable, Sendable { case deleted, stay, quitAllowed, stale }

/// Владелец RAM не исполняет события, не раскрывает payload и не управляет системным gate или UI.
@MainActor
final class RecoveryCoordinator {
    private let gateFactory: RecoveryGateFactory
    private var preparing: UUID?
    private var preparationValid = false
    private var reservation: PreparedRecoveryAdmission?
    private var record: StoredRecord?
    private var activeIntent: RecoveryUserIntent?
    private var resolvedIntent: (intent: RecoveryUserIntent, result: RecoveryUserDecisionResult)?
    private var permissionsAvailable = true
    private var secureInput = false
    private(set) var isEnabled = true

    init(gateFactory: RecoveryGateFactory? = nil) { self.gateFactory = gateFactory ?? .unavailable }

    var metadata: RecoveryMetadata? { record?.metadata }
    var hasPendingRecovery: Bool { record != nil }

    func reserve(
        operation: ConversionSafetyOperationToken, target: RecoveryProcessIdentity
    ) -> PreparedRecoveryAdmission? {
        guard mayPrepare, preparing == nil, reservation == nil, record == nil else { return nil }
        let identifier = UUID()
        preparing = identifier
        preparationValid = true
        defer {
            if preparing == identifier {
                preparing = nil
                preparationValid = false
            }
        }
        let scope = RecoveryOperationTarget(operation: operation, target: target)
        guard let gate = gateFactory.prepare(scope), mayPrepare, preparing == identifier, preparationValid,
              gate.isCurrent(for: scope) else { return nil }
        let prepared = PreparedRecoveryAdmission(scope: scope, gate: gate)
        reservation = prepared
        return prepared
    }

    /// Отклонение до claim оставляет batch исходному владельцу. Gate loss не запрещает сохранение префикса.
    func adopt(
        _ batch: HeldInputBatch, sealed: RecoveryAdmissionSeal,
        claim: ConversionSafetyInputClaim, reason: RecoveryReason
    ) -> RecoveryAdoptionResult {
        guard record == nil, let reservation else { return .rejected(.noReservation) }
        guard reservation.owns(sealed), batch.token == sealed.binding.hold,
              claim.operation == sealed.binding.scope.operation, claim.owner == .recovery else {
            return .rejected(.wrongBinding)
        }
        guard batch.eventCount == sealed.counts.events else { return .rejected(.countMismatch) }
        guard let events = batch.claim() else { return .rejected(.alreadyClaimed) }
        let stored = StoredRecord(admission: reservation, sealed: sealed, events: events, reason: reason)
        stored.protection = protectionStatus
        record = stored
        self.reservation = nil
        return .adopted(stored.identifier)
    }

    /// Вызывается только после scoped buffer.end по отдельному решению safety ledger. Сам replay не выполняется.
    func completeOrdinary(sealed: RecoveryAdmissionSeal, claim: ConversionSafetyInputClaim) -> Bool {
        guard record == nil, let reservation, reservation.owns(sealed),
              claim.operation == sealed.binding.scope.operation, claim.owner == .ordinaryDelivery else { return false }
        self.reservation = nil
        return true
    }

    func abandonBeforeHold(_ prepared: PreparedRecoveryAdmission) -> Bool {
        guard reservation === prepared, prepared.abandonBeforeHold() else { return false }
        reservation = nil
        return true
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled {
            preparationValid = false
            reservation?.stop(.interceptionStopped)
        }
        record?.protection = protectionStatus
    }

    func permissionsLost() {
        preparationValid = false
        permissionsAvailable = false
        reservation?.stop(.gateUnavailable)
        record?.protection = protectionStatus
    }

    func secureInputBegan() {
        preparationValid = false
        secureInput = true
        reservation?.stop(.secureInput)
        record?.protection = protectionStatus
    }

    func permissionsRestored() {
        // Возврат прав не является разрешением старой операции, replay или снятием quarantine.
        permissionsAvailable = true
        record?.protection = protectionStatus
    }

    func secureInputEnded() {
        secureInput = false
        record?.protection = protectionStatus
    }

    func hide() { record?.isVisible = false }
    func show() { record?.isVisible = true }

    func requestDeletion() -> RecoveryUserIntent? {
        guard let record else { return nil }
        return intent(for: record.identifier, purpose: .deletePayload)
    }

    func confirmDeletion(_ intent: RecoveryUserIntent) -> RecoveryUserDecisionResult {
        guard intent.purpose == .deletePayload else { return .stale }
        if let resolvedIntent, resolvedIntent.intent == intent { return resolvedIntent.result }
        guard let record, activeIntent == intent, intent.record == record.identifier,
              intent.purpose == .deletePayload else { return .stale }
        record.events = nil
        return resolve(intent, result: .deleted)
    }

    func cancelDeletion(_ intent: RecoveryUserIntent) -> RecoveryUserDecisionResult {
        guard intent.purpose == .deletePayload else { return .stale }
        if let resolvedIntent, resolvedIntent.intent == intent { return resolvedIntent.result }
        guard let record, activeIntent == intent, intent.record == record.identifier else { return .stale }
        return resolve(intent, result: .stay)
    }

    func requestQuit() -> RecoveryQuitRequest {
        guard preparing == nil, reservation == nil else { return .handoverRequired }
        guard let record else { return .allowed }
        return .confirmationRequired(intent(for: record.identifier, purpose: .quit))
    }

    func decideQuit(_ intent: RecoveryUserIntent, choice: RecoveryQuitChoice) -> RecoveryUserDecisionResult {
        guard intent.purpose == .quit else { return .stale }
        if let resolvedIntent, resolvedIntent.intent == intent { return resolvedIntent.result }
        guard let record, activeIntent == intent, intent.record == record.identifier,
              intent.purpose == .quit else { return .stale }
        switch choice {
        case .stay: return resolve(intent, result: .stay)
        case .deleteAndQuit:
            record.events = nil
            return resolve(intent, result: .quitAllowed)
        }
    }

    private func intent(for record: UUID, purpose: RecoveryUserIntent.Purpose) -> RecoveryUserIntent {
        if let activeIntent, activeIntent.record == record, activeIntent.purpose == purpose { return activeIntent }
        let created = RecoveryUserIntent(record: record, purpose: purpose)
        activeIntent = created
        return created
    }

    private var mayPrepare: Bool { isEnabled && permissionsAvailable && !secureInput }

    private var protectionStatus: RecoveryProtectionStatus {
        if !isEnabled { return .interceptionOff }
        return permissionsAvailable && !secureInput ? .unverified : .unavailable
    }

    private func resolve(
        _ intent: RecoveryUserIntent, result: RecoveryUserDecisionResult
    ) -> RecoveryUserDecisionResult {
        activeIntent = nil
        resolvedIntent = (intent, result)
        return result
    }

    /// Даже удаление payload не доказывает безопасность цели и не освобождает admission нового запроса.
    private final class StoredRecord {
        let identifier = UUID()
        let admission: PreparedRecoveryAdmission
        let sealed: RecoveryAdmissionSeal
        let reason: RecoveryReason
        var events: [CGEvent]?
        var isVisible = true
        var protection = RecoveryProtectionStatus.unverified

        init(
            admission: PreparedRecoveryAdmission, sealed: RecoveryAdmissionSeal,
            events: [CGEvent], reason: RecoveryReason
        ) {
            self.admission = admission
            self.sealed = sealed
            self.events = events
            self.reason = reason
        }

        var metadata: RecoveryMetadata {
            RecoveryMetadata(identifier: identifier, binding: sealed.binding, reason: reason,
                             eventCount: events?.count ?? 0, utf16Bytes: events == nil ? 0 : sealed.counts.utf16Bytes,
                             payloadDeleted: events == nil, isVisible: isVisible, protection: protection)
        }
    }
}
