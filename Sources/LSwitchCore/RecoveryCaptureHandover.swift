import Foundation

/// Совпадение числового поколения не заменяет identity операции, очереди и экземпляра tap.
struct RecoveryCaptureScope: Equatable, Sendable {
    let binding: RecoveryHoldBinding
    let tapIdentifier: UUID
}

/// Подготовленный адаптер держит защиту получателя на всём протяжении синхронного body.
/// Он сверяет полный scope внутри своей критической секции и не сохраняет body для позднего вызова.
/// Body выполняет только scoped detach; admission/coordinator/UI/IPC внутри него запрещены.
final class PreparedRecoveryHandover: @unchecked Sendable {
    let operationScope: RecoveryOperationTarget
    let tapIdentifier: UUID
    private let protecting: @Sendable (RecoveryCaptureScope, () -> Void) -> Void

    init(
        operationScope: RecoveryOperationTarget, tapIdentifier: UUID,
        protecting: @escaping @Sendable (RecoveryCaptureScope, () -> Void) -> Void
    ) {
        self.operationScope = operationScope
        self.tapIdentifier = tapIdentifier
        self.protecting = protecting
    }

    func withProtection(for scope: RecoveryCaptureScope, body: () -> Void) {
        protecting(scope) {
            guard scope.binding.scope == self.operationScope, scope.tapIdentifier == self.tapIdentifier else { return }
            body()
        }
    }
}

/// Production handover не допущен. Создание объекта/окна не заменяет системный контракт.
@MainActor
struct RecoveryCaptureHandoverFactory {
    var prepare: (RecoveryOperationTarget, UUID) -> PreparedRecoveryHandover?
    static var unavailable: Self { Self(prepare: { _, _ in nil }) }
}

enum RecoveryCaptureClosure: Equatable, Sendable {
    case wrongScope
    case awaitingProtection(RecoveryAdmissionCounts)
    case detached(RecoveryAdmissionCounts)
    case transferred(UUID)
}

enum RecoveryOperationAdoption: Equatable, Sendable {
    case awaitingDetach, awaitingDecision, ordinaryDeliveryUnavailable
    case adopted(UUID)
    case rejected(RecoveryAdoptionFailure)
}
