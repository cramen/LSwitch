import ApplicationServices
import Foundation

struct AXConversionExecution {
    let result: ConversionResult
    let wasSelection: Bool
    let cleanup: ConversionSafetyCleanupEvidence
}

/// Совместимость без ledger отделена от нового пути с обязательным bound-контрактом.
@MainActor
final class AXMutationSafety {
    let request: ConversionRequest
    private let receiverContract: AXReceiverContract?
    private let profile: AXObservationProfile?
    private var binding: AXBoundReceiverContract?
    private var pending: [ConversionSafetySubmissionToken: AXWriteReply] = [:]
    private var noWorkObserved = false
    private(set) var attempted = false
    private(set) var cleanup: ConversionSafetyCleanupEvidence = .noOwnedMutation

    init(request: ConversionRequest, receiverContract: AXReceiverContract?, profile: AXObservationProfile? = nil) {
        self.request = request
        self.receiverContract = receiverContract
        self.profile = profile
    }

    var isProfileMode: Bool { request.safetyLedger?.profileBinding != nil }

    var permitsNoWorkResult: Bool {
        noWorkObserved && !attempted && !Task.isCancelled && request.safetyLedger?.submissionCount == 0
            && request.safetyLedger?.hasProfileFault == false && request.safetyLedger?.encounteredUnknown == false
            && request.safetyLedger?.decision == nil
    }

    /// Единственное исключение из blanket fault: подтверждённое отсутствие слова в ручном запросе.
    func observeNoWork(_ snapshot: SelectionSettlement.State) -> Bool {
        guard isProfileMode, request.useSelection, request.expectedWord == nil, request.replacement == nil,
              snapshot.selection.length == 0, let cursor = Range(snapshot.selection, in: snapshot.text)?.lowerBound,
              WordBoundary.lastWord(in: snapshot.text, beforeCursor: cursor) == nil,
              !attempted, let ledger = request.safetyLedger, ledger.submissionCount == 0,
              !ledger.hasProfileFault, !ledger.encounteredUnknown, ledger.decision == nil,
              profileRead(.init(snapshot.text, snapshot.selection)) != nil,
              !attempted, ledger.submissionCount == 0, !ledger.hasProfileFault,
              !ledger.encounteredUnknown, ledger.decision == nil, !Task.isCancelled else { return false }
        noWorkObserved = true
        return true
    }

    func bind(to element: AXUIElement) -> Bool {
        guard let ledger = request.safetyLedger else { return profile == nil }
        if isProfileMode {
            return profile?.bind(to: element, ledger: ledger, isValid: request.isValid) == true
        }
        guard let binding = receiverContract?.bind(element, ledger.operation),
              binding.isValid(for: element, operation: ledger.operation) else { return false }
        self.binding = binding
        return true
    }

    func writeSelection(
        _ range: NSRange, in element: AXUIElement, access: any AXTextAccess,
        restoring: Bool = false, isValid: () -> Bool
    ) -> Bool {
        guard isValid() else { return false }
        guard request.safetyLedger != nil else {
            markAttempt()
            return access.setSelection(range, in: element)
        }
        guard let prepared = access.prepareSelection(range, in: element) else { return false }
        return submit(prepared, kind: restoring ? .restoreSelection : .selection, in: element, isValid: isValid)
    }

    func writeText(
        _ text: String, in element: AXUIElement, access: any AXTextAccess, isValid: () -> Bool
    ) -> Bool {
        guard isValid() else { return false }
        guard request.safetyLedger != nil else {
            markAttempt()
            return access.replaceSelectedText(text, in: element)
        }
        guard let prepared = access.prepareReplacement(text, in: element) else { return false }
        return submit(prepared, kind: .text, in: element, isValid: isValid)
    }

    /// Полный snapshot — вход принятого receiver-контракта, но не самостоятельное доказательство completion.
    func requireCompletion(_ observation: AXWriteObservation, expected: AXProfileExpectedState? = nil) -> Bool {
        guard request.safetyLedger != nil else { return true }
        if isProfileMode { return acceptProfileStep(observation, expected: expected) }
        resolve(observation)
        guard pending.isEmpty else { markUnknown(); return false }
        return request.safetyLedger?.encounteredUnknown == false
    }

    @discardableResult
    func recordCleanup(
        _ evidence: ConversionSafetyCleanupEvidence, validateFresh: () -> Bool
    ) -> ConversionSafetyCleanupEvidence {
        cleanup = attempted ? evidence : .noOwnedMutation
        guard let ledger = request.safetyLedger else { return cleanup }
        if evidence == .recoveredObserved { resolve(.cleanupSettled) }
        markUnknown()
        guard let observation = ledger.beginCleanupObservation(operation: ledger.operation) else {
            cleanup = .recoveryUnconfirmed
            failProfile(.cleanupUnconfirmed)
            return cleanup
        }
        if evidence == .recoveredObserved, !validateFresh() { cleanup = .recoveryUnconfirmed }
        if !ledger.recordCleanup(cleanup, observation: observation) {
            cleanup = .recoveryUnconfirmed
            failProfile(.cleanupUnconfirmed)
        }
        return cleanup
    }

    func finishEvidence() {
        markUnknown()
        if let ledger = request.safetyLedger {
            if ledger.recordedCleanup == nil { recordCleanup(cleanup, validateFresh: { false }) }
            // Чужое более позднее наблюдение не повышает отвергнутый результат этой проверки.
            if ledger.recordedCleanup != cleanup {
                cleanup = .recoveryUnconfirmed
                failProfile(.cleanupUnconfirmed)
            }
        }
    }

    /// Каждый отказ B делает cleanup read-only, даже если более позднее чтение снова совпало.
    func failProfile(_ reason: ConversionSafetyProfileFault) {
        guard isProfileMode, let ledger = request.safetyLedger else { return }
        ledger.recordProfileFault(reason, operation: ledger.operation)
    }

    func profileRead(_ expected: AXProfileExpectedState?) -> AXProfileSnapshot? {
        guard let ledger = request.safetyLedger, let profile else {
            failProfile(.preparationFailed)
            return nil
        }
        return profile.read(expected: expected, ledger: ledger)
    }

    func observeProfileFinal(_ expected: AXProfileExpectedState) -> Bool {
        guard isProfileMode else { return true }
        guard let ledger = request.safetyLedger, let profile else { return false }
        return profile.observe(step: .finalState, reply: nil, expected: expected, ledger: ledger)
    }

    var permitsReceipt: Bool {
        guard let ledger = request.safetyLedger else { return true }
        guard ledger.decision == nil, !ledger.encounteredUnknown, !ledger.hasOutstandingKeyDebt else { return false }
        if isProfileMode {
            return !ledger.hasProfileFault && !ledger.hasUnacceptedSubmissions && ledger.hasObservedProfileFinalState
        }
        return !ledger.hasUnresolvedSubmissions
    }

    func textMatches(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        return request.safetyLedger == nil ? lhs == rhs : lhs.utf16.elementsEqual(rhs.utf16)
    }

    func cleanupCaret(_ plan: AXReplacementPlan, text: String, selection: NSRange) -> NSRange? {
        if request.safetyLedger == nil { return plan.cleanupCaret(in: text, selection: selection) }
        guard selection.length > 0, let originalRange = Range(plan.range, in: plan.text),
              let selectedRange = Range(selection, in: text) else { return nil }
        let insertionPoint = originalRange.upperBound
        let inserted = plan.text.replacingCharacters(in: insertionPoint..<insertionPoint, with: plan.replacement)
        guard textMatches(text, plan.resultingText) || textMatches(text, inserted) else { return nil }
        let selected = String(text[selectedRange])
        let original = selection == plan.range
            && textMatches(selected, plan.receipt.original + plan.receipt.trailingText)
        let replacement = textMatches(selected, plan.replacement)
            && (selection.location == plan.range.location || selection.location == NSMaxRange(plan.range))
        return original || replacement ? NSRange(location: NSMaxRange(selection), length: 0) : nil
    }

    private func submit(
        _ prepared: AXPreparedWrite, kind: ConversionSafetySubmissionKind,
        in element: AXUIElement, isValid: () -> Bool
    ) -> Bool {
        guard let ledger = request.safetyLedger else { return false }
        let reply = prepared.submit {
            guard isValid(), self.hasCurrentBinding(element, ledger: ledger),
                  kind.isCleanup || !Task.isCancelled else { return nil }
            let token = kind == .restoreSelection
                ? ledger.willSubmitCleanup(kind, operation: ledger.operation)
                : ledger.willSubmit(kind, operation: ledger.operation)
            if token != nil { self.markAttempt() }
            return token
        }
        guard let reply else { return false }
        pending[reply.submission] = reply
        ledger.observe(.adapterReturned(reply.status == .success), for: reply.submission)
        if reply.status != .success { ledger.observe(.unknown, for: reply.submission) }
        return reply.status == .success
    }

    private func markAttempt() {
        attempted = true
        cleanup = .recoveryUnconfirmed
    }

    private func hasCurrentBinding(_ element: AXUIElement, ledger: ConversionSafetyLedger) -> Bool {
        if isProfileMode { return profile?.isCurrent(ledger: ledger) == true }
        return binding?.isValid(for: element, operation: ledger.operation) == true
    }

    private func acceptProfileStep(_ observation: AXWriteObservation, expected: AXProfileExpectedState?) -> Bool {
        guard let ledger = request.safetyLedger, let profile, let expected else {
            failProfile(.snapshotUnavailable)
            return false
        }
        let step: ConversionSafetyProfileStep
        switch observation {
        case .selectedRangeSettled: step = .selection
        case .replacementObserved: step = .text
        case .finalStateSettled, .cleanupSettled: step = .restoreSelection
        }
        for (token, reply) in pending.sorted(by: { $0.key.ordinal < $1.key.ordinal }) {
            guard profile.observe(step: step, reply: reply, expected: expected, ledger: ledger) else {
                markUnknown()
                return false
            }
            pending.removeValue(forKey: token)
        }
        return pending.isEmpty && !ledger.hasProfileFault && !ledger.encounteredUnknown
    }

    private func resolve(_ observation: AXWriteObservation) {
        guard let ledger = request.safetyLedger, let binding else { return }
        for (token, reply) in pending {
            guard binding.evidence(for: reply, observation: observation) == .receiverCompleted,
                  ledger.observe(.receiverCompleted, for: token) else { continue }
            pending.removeValue(forKey: token)
        }
    }

    private func markUnknown() {
        guard let ledger = request.safetyLedger else { return }
        for token in pending.keys { ledger.observe(.unknown, for: token) }
    }
}
