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
    private var binding: AXBoundReceiverContract?
    private var pending: [ConversionSafetySubmissionToken: AXWriteReply] = [:]
    private(set) var attempted = false
    private(set) var cleanup: ConversionSafetyCleanupEvidence = .noOwnedMutation

    init(request: ConversionRequest, receiverContract: AXReceiverContract?) {
        self.request = request
        self.receiverContract = receiverContract
    }

    func bind(to element: AXUIElement) -> Bool {
        guard let ledger = request.safetyLedger else { return true }
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
    func requireCompletion(_ observation: AXWriteObservation) -> Bool {
        guard request.safetyLedger != nil else { return true }
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
            return cleanup
        }
        if evidence == .recoveredObserved, !validateFresh() { cleanup = .recoveryUnconfirmed }
        if !ledger.recordCleanup(cleanup, observation: observation) { cleanup = .recoveryUnconfirmed }
        return cleanup
    }

    func finishEvidence() {
        markUnknown()
        if let ledger = request.safetyLedger {
            if ledger.recordedCleanup == nil { recordCleanup(cleanup, validateFresh: { false }) }
            // Чужое более позднее наблюдение не повышает отвергнутый результат этой проверки.
            if ledger.recordedCleanup != cleanup { cleanup = .recoveryUnconfirmed }
        }
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
        guard let ledger = request.safetyLedger, let binding else { return false }
        let reply = prepared.submit {
            guard isValid(), binding.isValid(for: element, operation: ledger.operation),
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
