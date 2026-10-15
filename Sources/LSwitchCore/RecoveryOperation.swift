import Foundation

/// Удерживается владельцем приложения, а не только task/tap. Деструктор не исполняет события.
/// До wiring этот компонент не заменяет legacy endInputHold и не выдаёт ordinary replay permit.
@MainActor
final class RecoveryOperation {
    let ledger: ConversionSafetyLedger
    let capturePort: RecoveryCapturePort
    private var recoveryClaim: ConversionSafetyInputClaim?

    private init(ledger: ConversionSafetyLedger, capturePort: RecoveryCapturePort) {
        self.ledger = ledger
        self.capturePort = capturePort
    }

    /// Вся подготовка заканчивается до публикации capturePort. Неуспех не принимал ни одного события.
    static func prepare(
        ledger: ConversionSafetyLedger, admission: PreparedRecoveryAdmission,
        tapIdentifier: UUID, at now: UInt64, handoverFactory: RecoveryCaptureHandoverFactory? = nil
    ) -> RecoveryOperation? {
        guard ledger.operation == admission.scope.operation, ledger.submissionCount == 0, ledger.decision == nil,
              let handover = (handoverFactory ?? .unavailable).prepare(admission.scope, tapIdentifier),
              handover.operationScope == admission.scope, handover.tapIdentifier == tapIdentifier,
              ledger.submissionCount == 0, ledger.decision == nil else { return nil }
        let buffer = InputEventBuffer()
        guard let token = buffer.beginHold(at: now), let binding = admission.bindHold(token) else { return nil }
        let port = RecoveryCapturePort(scope: .init(binding: binding, tapIdentifier: tapIdentifier), buffer: buffer,
                                       admission: admission, handover: handover)
        return RecoveryOperation(ledger: ledger, capturePort: port)
    }

    func closeCapture() -> RecoveryCaptureClosure { capturePort.close(scope: capturePort.scope) }

    /// Finish остаётся явным решением владельца. Повторный rejected adopt использует тот же единственный claim.
    func adopt(in coordinator: RecoveryCoordinator, reason: RecoveryReason) -> RecoveryOperationAdoption {
        guard let decision = ledger.decision else { return .awaitingDecision }
        guard decision.input == .recoveryRequired else { return .ordinaryDeliveryUnavailable }
        if recoveryClaim == nil { recoveryClaim = ledger.claimInput(operation: ledger.operation) }
        guard let recoveryClaim else { return .rejected(.wrongBinding) }
        return capturePort.adopt(in: coordinator, claim: recoveryClaim, reason: reason)
    }
}
