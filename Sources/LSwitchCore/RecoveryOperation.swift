import Foundation

/// Удерживается владельцем приложения, а не только task/tap. Деструктор не исполняет события.
/// До wiring этот компонент не заменяет legacy endInputHold и не выдаёт ordinary replay permit.
@MainActor
final class RecoveryOperation {
    let ledger: ConversionSafetyLedger
    let capturePort: RecoveryCapturePort
    private var recoveryClaim: ConversionSafetyInputClaim?
    private var storageDetached = false

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
                                       admission: admission, handover: handover,
                                       holdDeadline: now + InputEventBuffer.maximumDuration)
        return RecoveryOperation(ledger: ledger, capturePort: port)
    }

    func closeCapture() -> RecoveryCaptureClosure { capturePort.close(scope: capturePort.scope) }

    /// Повторяется только проверка локального quiescence; новых мутаций или системных допусков здесь нет.
    func closeCaptureForStorage(router: RecoveryCaptureRouter, attachment: RecoveryCaptureAttachment) -> Bool {
        guard router.identifier == capturePort.scope.tapIdentifier, attachment.port === capturePort else {
            return false
        }
        if storageDetached { return true }
        guard router.beginRetirement(attachment),
              let seal = capturePort.trySealForStorage(scope: capturePort.scope),
              let proof = router.retiredProof(seal: seal), capturePort.detachForStorage(proof: proof) else {
            return false
        }
        storageDetached = true
        _ = router.detach(attachment)
        return true
    }

    /// Finish остаётся явным решением владельца. Повторный rejected adopt использует тот же единственный claim.
    func adopt(in coordinator: RecoveryCoordinator, reason: RecoveryReason) -> RecoveryOperationAdoption {
        guard ledger.decision != nil else { return .awaitingDecision }
        guard ledger.currentInputDisposition == .recoveryRequired else { return .ordinaryDeliveryUnavailable }
        if recoveryClaim == nil { recoveryClaim = ledger.claimInput(operation: ledger.operation) }
        guard let recoveryClaim else { return .rejected(.wrongBinding) }
        return capturePort.adopt(in: coordinator, claim: recoveryClaim, reason: reason)
    }
}
