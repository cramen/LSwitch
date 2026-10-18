import Foundation

/// Отдельный от результата текста учёт native/Unicode отправок. Общий ledger завершает внешний владелец.
@MainActor
final class UnicodeMutationSafety {
    let request: ConversionRequest
    private var binding: UnicodeBoundReceiverContract?
    private var pending: [ConversionSafetySubmissionToken: ConversionDispatchReply] = [:]
    private var kinds: [ConversionSafetySubmissionToken: ConversionSafetySubmissionKind] = [:]
    private var completedText = false
    private var debt = Set<ConversionSafetySubmissionToken>()
    private(set) var submittedText = false
    private(set) var cleanup = ConversionSafetyCleanupEvidence.noOwnedMutation

    init(request: ConversionRequest) { self.request = request }

    func bind(target: UnicodeReceiverTarget, contract: UnicodeReceiverContract?) -> Bool {
        guard let ledger = request.safetyLedger else { return true }
        guard let bound = contract?.bind(target, ledger.operation), bound.target == target,
              bound.operation == ledger.operation, bound.isCurrent(), bound.canBalance(), !Task.isCancelled,
              bound.nativeBinding?.belongs(to: ledger) != false,
              ledger.permitsOrdinarySubmission, !ledger.hasUnresolvedSubmissions else { return false }
        binding = bound
        return true
    }

    func hooks(isValid: @escaping @MainActor () -> Bool) -> ConversionDispatchHooks? {
        guard request.safetyLedger != nil else { return nil }
        return .init(beforeSend: { self.beforeSend($0, isValid: isValid) }, didReturn: { self.didReturn($0) },
                     submissionCount: { self.request.safetyLedger?.submissionCount ?? 0 }, didLeaveDebt: {
            self.debt.insert($0)
            self.request.safetyLedger?.recordOutstandingKeyDebt(for: $0)
        }, nativeBinding: binding?.nativeBinding)
    }

    private func beforeSend(
        _ kind: ConversionSafetySubmissionKind, isValid: @MainActor () -> Bool
    ) -> ConversionSafetySubmissionToken? {
        guard let ledger = request.safetyLedger, let binding else { return nil }
        let token: ConversionSafetySubmissionToken?
        if kind == .balancingRelease {
            guard binding.canBalance() else { return nil }
            token = ledger.willSubmitCleanup(kind, operation: ledger.operation)
        } else if kind.isCleanup {
            guard isValid(), binding.isCurrent(), binding.canBalance() else { return nil }
            token = ledger.willSubmitCleanup(kind, operation: ledger.operation)
        } else {
            guard !Task.isCancelled, isValid(), binding.isCurrent(), binding.canBalance() else { return nil }
            token = ledger.willSubmit(kind, operation: ledger.operation)
        }
        if let token {
            kinds[token] = kind
            if kind.changesEditor { cleanup = .recoveryUnconfirmed }
            if kind == .text { submittedText = true }
        }
        return token
    }

    private func didReturn(_ reply: ConversionDispatchReply) {
        guard let ledger = request.safetyLedger else { return }
        pending[reply.submission] = reply
        ledger.observe(.adapterReturned(reply.returnedSuccessfully), for: reply.submission)
        if !reply.returnedSuccessfully { ledger.observe(.unknown, for: reply.submission) }
    }

    func requireCompletion(_ observation: UnicodeReceiverObservation) -> Bool {
        guard let ledger = request.safetyLedger else { return true }
        resolve(observation)
        guard !ledger.hasUnresolvedSubmissions else { markUnknown(); return false }
        return !ledger.encounteredUnknown && ledger.decision == nil
    }

    private func resolve(_ observation: UnicodeReceiverObservation) {
        guard let ledger = request.safetyLedger, let binding else { return }
        for (token, reply) in pending {
            let accepted: Bool
            switch binding.evidence(for: reply, observation: observation) {
            case .unresolved: continue
            case .receiverCompleted:
                accepted = ledger.observe(.receiverCompleted, for: token)
                if accepted, kinds[token] == .text { completedText = true }
            case .preventedBeforeAdmission:
                accepted = ledger.observe(.preventedBeforeAdmission, for: token)
            }
            if accepted { pending.removeValue(forKey: token) }
        }
    }

    func recordCleanup(validateFresh: () -> Bool) {
        guard let ledger = request.safetyLedger else { return }
        resolve(.cleanupSettled)
        markUnknown()
        guard let ticket = ledger.beginCleanupObservation(operation: ledger.operation) else {
            cleanup = .recoveryUnconfirmed
            return
        }
        cleanup = ledger.hasEditorMutation ? .recoveryUnconfirmed : .noOwnedMutation
        if ledger.hasEditorMutation, debt.isEmpty, validateFresh() { cleanup = .recoveredObserved }
        if !debt.isEmpty { cleanup = .recoveryUnconfirmed }
        if !ledger.recordCleanup(cleanup, observation: ticket) { cleanup = .recoveryUnconfirmed }
    }

    var permitsReceipt: Bool {
        guard let ledger = request.safetyLedger else { return true }
        return !Task.isCancelled && ledger.decision == nil && !ledger.encounteredUnknown
            && !ledger.hasUnresolvedSubmissions && !ledger.hasOutstandingKeyDebt
            && completedText && cleanup == .recoveredObserved
            && ledger.recordedCleanup == cleanup
    }

    private func markUnknown() {
        guard let ledger = request.safetyLedger else { return }
        for token in pending.keys { ledger.observe(.unknown, for: token) }
    }
}
