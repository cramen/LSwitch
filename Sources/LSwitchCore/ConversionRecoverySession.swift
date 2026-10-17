import Foundation

/// Один ledger и один владелец capture. Deinit не выполняет release/post или повторный claim.
/// Пока системный transport не принят, Session создают только внутренние компонентные providers.
@MainActor
public final class ConversionRecoverySession {
    public let ledger: ConversionSafetyLedger
    public let allowedMechanisms: [ConversionDiagnostics.Mechanism]
    public private(set) var requiresRecovery = false
    public private(set) var ordinaryOwnershipUnconfirmed = false
    public private(set) var ordinaryTransportRetained = false
    private let context: ConversionRecoveryContext
    private let adapter: any ConversionRecoveryAdapter
    private let identifier = UUID()
    private var preparation: ConversionRecoveryPreparation?
    private var claim: ConversionSafetyInputClaim?
    private var transport: ConversionOrdinaryTransport?
    private var awaitingTransport = false
    private var retentionRequestedDuringCommit = false
    private var phase = Phase.active
    private enum Phase { case active, preparing, prepared, committing, transportPending, ordinaryTransferred, retained }

    init?(
        context: ConversionRecoveryContext, ledger: ConversionSafetyLedger,
        allowedMechanisms: [ConversionDiagnostics.Mechanism], adapter: any ConversionRecoveryAdapter
    ) {
        guard ledger.operation.generation == context.generation, ledger.decision == nil,
              ledger.inputOwner == .transaction, !allowedMechanisms.isEmpty,
              !allowedMechanisms.contains(.none),
              ledger.profileBinding == nil || allowedMechanisms.allSatisfy({ $0 == .accessibility }) else { return nil }
        self.context = context
        self.ledger = ledger
        self.allowedMechanisms = allowedMechanisms
        self.adapter = adapter
        guard context.isCurrent(), !Task.isCancelled else { return nil }
        guard context.admission.register(self) else { return nil }
        if !adapter.activateCapture() { retainIfUnfinished() }
    }

    func matches(_ expected: ConversionRecoveryContext) -> Bool {
        context.identifier == expected.identifier && phase == .active
    }

    var ordinaryTransferred: Bool { phase == .ordinaryTransferred }
    public var isTransportPending: Bool { phase == .transportPending }

    var isValid: Bool {
        guard phase == .active else { return false }
        guard !Task.isCancelled else { fault(.cancelled); return false }
        guard context.isCurrent() else { fault(.contextChanged); return false }
        guard adapter.isCaptureValid else { fault(.preparationFailed); return false }
        return phase == .active && ledger.decision == nil && !ledger.hasProfileFault && !ledger.encounteredUnknown
    }

    var canCleanup: Bool { context.canCleanup() }

    func beginMutation() -> Bool {
        guard isValid, ledger.permitsOrdinarySubmission, adapter.beginMutation() else {
            fault(.preparationFailed)
            return false
        }
        return isValid
    }

    func drainPendingInput() async { await adapter.drainPendingInput() }

    func allows(_ mechanism: ConversionDiagnostics.Mechanism) -> Bool { allowedMechanisms.contains(mechanism) }

    var permitsFallback: Bool {
        isValid && ledger.submissionCount == 0 && !ledger.hasOutstandingKeyDebt && ledger.decision == nil
    }

    func prepareFinalization(
        text: ConversionSafetyTextEvidence, ordinaryRouteValid: Bool
    ) -> ConversionRecoveryPreparation? {
        guard phase == .active else { return nil }
        let current = ordinaryRouteValid && isValid
        guard phase == .active else { return nil }
        phase = .preparing
        let routePrepared = current && adapter.prepareOrdinary()
        let routeCurrent = routePrepared && adapter.isOrdinaryRouteCurrent && context.isCurrent() && !Task.isCancelled
        guard let decision = ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: text, ordinaryRouteValid: routeCurrent
        ) else { retainIfUnfinished(); return nil }
        guard ledger.currentInputDisposition == .replayAuthorized,
              text != .confirmed || ledger.permitsConfirmedResult else {
            retainIfUnfinished()
            return nil
        }
        let prepared = ConversionRecoveryPreparation(session: identifier, decision: decision)
        preparation = prepared
        phase = .prepared
        return prepared
    }

    /// Последними читаются только чистые состояния: внешние route/context callbacks могут войти повторно.
    func permitsFinalEffects(_ expected: ConversionRecoveryPreparation) -> Bool {
        guard phase == .prepared, expected.session == identifier,
              preparation?.decision == expected.decision else { return false }
        guard adapter.isOrdinaryRouteCurrent, context.isCurrent(), !Task.isCancelled else { return false }
        return phase == .prepared && preparation?.session == expected.session
            && preparation?.decision == expected.decision && ledger.currentInputDisposition == .replayAuthorized
            && ledger.permitsConfirmedResult
    }

    func commitOrdinary(
        _ expected: ConversionRecoveryPreparation, correction: ConversionRecoveryLayoutTransition?
    ) -> ConversionRecoveryCompletion {
        if phase == .ordinaryTransferred { return .alreadyFinalized }
        guard phase == .prepared, preparation?.session == expected.session, expected.session == identifier,
              preparation?.decision == expected.decision,
              adapter.isOrdinaryRouteCurrent, context.isCurrent(),
              phase == .prepared, ledger.currentInputDisposition == .replayAuthorized, !Task.isCancelled else {
            retainIfUnfinished()
            return .retained
        }
        phase = .committing
        let acceptance = adapter.commitOrdinary(correction: correction) { [self] in
            // Transport может держать короткий RAM lock: никаких внешних callbacks внутри claim.
            guard phase == .committing, claim == nil, preparation?.session == expected.session,
                  preparation?.decision == expected.decision,
                  ledger.currentInputDisposition == .replayAuthorized, !Task.isCancelled else { return nil }
            claim = ledger.claimInput(operation: ledger.operation)
            return claim
        }
        guard case .accepted(let accepted) = acceptance else {
            ordinaryOwnershipUnconfirmed = claim?.owner == .ordinaryDelivery
            retainIfUnfinished()
            return .retained
        }
        transport = accepted
        guard claim?.owner == .ordinaryDelivery else {
            ordinaryOwnershipUnconfirmed = true
            accepted.requestRetention()
            retainIfUnfinished()
            return .retained
        }
        // Accepted ownership необратим, но ещё не означает локальную доставку.
        phase = .transportPending
        if retentionRequestedDuringCommit { accepted.requestRetention() }
        requiresRecovery = false
        ordinaryOwnershipUnconfirmed = false
        preparation = nil
        return .transportAccepted
    }

    func awaitOrdinaryCompletion() async -> ConversionRecoveryCompletion {
        guard phase == .transportPending, !awaitingTransport, let transport else { return .alreadyFinalized }
        awaitingTransport = true
        let result = await transport.waitForTerminal()
        awaitingTransport = false
        // После claim контекст не отменяет уже состоявшуюся доставку. Будущий undo проверяет свой target.
        if result == .locallyDispatched {
            phase = .ordinaryTransferred
            requiresRecovery = false
            return .ordinaryTransferred
        }
        phase = .retained
        requiresRecovery = true
        ordinaryTransportRetained = result == .retainedFailure
        ordinaryOwnershipUnconfirmed = result == nil
        return .retained
    }

    /// Любой незавершённый путь сохраняет adapter/его очередь у Session. Старый endInputHold не вызывается.
    func retainIfUnfinished() {
        guard phase != .ordinaryTransferred, phase != .retained else { return }
        if ordinaryOwnershipUnconfirmed {
            phase = .retained
            requiresRecovery = true
            preparation = nil
            return
        }
        if phase == .committing, claim?.owner == .ordinaryDelivery {
            retentionRequestedDuringCommit = true
            return
        }
        if phase == .transportPending {
            transport?.requestRetention()
            return
        }
        if ledger.decision == nil {
            _ = ledger.finishUsingRecordedCleanup(
                operation: ledger.operation, text: .unknown, ordinaryRouteValid: false
            )
        }
        if ledger.currentInputDisposition == .replayAuthorized, claim == nil {
            _ = ledger.recordOrdinaryDeliveryRefusal(operation: ledger.operation)
        }
        if ledger.currentInputDisposition == .recoveryRequired, claim == nil {
            claim = ledger.claimInput(operation: ledger.operation)
        }
        phase = .retained
        requiresRecovery = true
        preparation = nil
        if claim?.owner != .ordinaryDelivery { adapter.retainForRecovery(claim: claim) }
    }

    private func fault(_ reason: ConversionSafetyProfileFault) {
        ledger.recordProfileFault(reason, operation: ledger.operation)
    }
}
