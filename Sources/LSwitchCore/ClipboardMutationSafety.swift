import Foundation

/// Учёт отправок не владеет clipboard и не завершает общий журнал транзакции.
@MainActor
final class ClipboardMutationSafety {
    let request: ConversionRequest
    private var binding: ClipboardBoundReceiverContract?
    private var pending: [ConversionSafetySubmissionToken: ClipboardDispatchReply] = [:]
    private var kinds: [ConversionSafetySubmissionToken: ConversionSafetySubmissionKind] = [:]
    private var completedText = false
    private var debt = Set<ConversionSafetySubmissionToken>()
    private(set) var submittedText = false
    private(set) var cleanup: ConversionSafetyCleanupEvidence = .noOwnedMutation

    init(request: ConversionRequest) { self.request = request }

    func bind(context: ClipboardEnvironment.Context, contract: ClipboardReceiverContract?) -> Bool {
        guard let ledger = request.safetyLedger else { return true }
        guard let bound = contract?.bind(context.identity, ledger.operation),
              bound.contextIdentity == context.identity, bound.operation == ledger.operation,
              bound.nativeBinding?.belongs(to: ledger) != false,
              bound.isCurrent(), bound.canBalance(), !Task.isCancelled, ledger.permitsOrdinarySubmission,
              !ledger.hasUnresolvedSubmissions else { return false }
        binding = bound
        return true
    }

    var permitsOrdinary: Bool {
        guard let ledger = request.safetyLedger else { return true }
        return !Task.isCancelled && binding?.isCurrent() == true && ledger.permitsOrdinarySubmission
    }

    func hooks(isValid: @escaping @MainActor () -> Bool) -> ClipboardDispatchHooks? {
        guard request.safetyLedger != nil else { return nil }
        return ClipboardDispatchHooks(beforeSend: { kind in
            self.beforeSend(kind, isValid: isValid)
        }, didReturn: { self.didReturn($0) }, submissionCount: { self.request.safetyLedger?.submissionCount ?? 0 },
        didLeaveDebt: {
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
            guard isValid(), permitsOrdinary, binding.canBalance() else { return nil }
            token = ledger.willSubmit(kind, operation: ledger.operation)
        }
        if token != nil, kind.changesEditor { cleanup = .recoveryUnconfirmed }
        if token != nil, kind == .text { submittedText = true }
        if let token { kinds[token] = kind }
        return token
    }

    private func didReturn(_ reply: ClipboardDispatchReply) {
        guard let ledger = request.safetyLedger else { return }
        pending[reply.submission] = reply
        ledger.observe(.adapterReturned(reply.returnedSuccessfully), for: reply.submission)
        if !reply.returnedSuccessfully { ledger.observe(.unknown, for: reply.submission) }
    }

    func resolve(_ observation: ClipboardReceiverObservation) {
        guard let ledger = request.safetyLedger, let binding else { return }
        for (token, reply) in pending {
            let evidence = binding.evidence(for: reply, observation: observation)
            let accepted: Bool
            switch evidence {
            case .unresolved: continue
            case .receiverCompleted: accepted = ledger.observe(.receiverCompleted, for: token)
            case .preventedBeforeAdmission: accepted = ledger.observe(.preventedBeforeAdmission, for: token)
            }
            if accepted {
                if evidence == .receiverCompleted, kinds[token] == .text { completedText = true }
                pending.removeValue(forKey: token)
            }
        }
    }

    func requireCompletion(_ observation: ClipboardReceiverObservation) -> Bool {
        guard let ledger = request.safetyLedger else { return true }
        resolve(observation)
        guard !ledger.hasUnresolvedSubmissions else { markUnknown(); return false }
        return !ledger.encounteredUnknown && ledger.decision == nil
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

    func markUnknown() {
        guard let ledger = request.safetyLedger else { return }
        for token in pending.keys { ledger.observe(.unknown, for: token) }
    }

    func textMatches(_ lhs: String, _ rhs: String) -> Bool {
        request.safetyLedger == nil ? lhs == rhs : lhs.utf16.elementsEqual(rhs.utf16)
    }
}
