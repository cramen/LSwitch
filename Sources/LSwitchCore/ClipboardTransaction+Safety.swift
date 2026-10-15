import Foundation

extension ClipboardTransaction {
    func dispatch(
        _ command: ClipboardCommand, isValid: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard let hooks = safety.hooks(isValid: isValid) else {
            return await environment.send(command, isValid)
        }
        let sent = await environment.sendTracked?(command, isValid, hooks) == true
        pasted = safety.submittedText
        safety.resolve(.commandReturned)
        return sent
    }

    func commitVerifiedPaste(_ plan: AXReplacementPlan) async -> MenuCommand.Outcome {
        let select = { await self.selectVerified(plan) }
        let check = { self.selectedStateMatches(plan) }
        let valid = { self.valid && self.environment.changeCount() == self.ownedCount }
        guard let hooks = safety.hooks(isValid: valid) else {
            return await environment.commitPaste(select, check, valid)
        }
        let result = await environment.commitPasteTracked?(select, check, valid, hooks) ?? .unavailable
        pasted = safety.submittedText
        safety.resolve(.commandReturned)
        return result
    }

    func setSelection(_ range: NSRange, cleanup: Bool) -> Bool {
        let valid = { cleanup ? self.cleanupAllowed : self.valid }
        guard valid() else { return false }
        guard let hooks = safety.hooks(isValid: valid) else { return context?.setSelection(range) == true }
        guard let prepared = context?.prepareSelection(range), let reply = prepared.submit(beforeSend: {
            hooks.beforeSend(cleanup ? .restoreSelection : .selection)
        }) else { return false }
        hooks.didReturn(.init(submission: reply.submission, transport: .accessibility, status: reply.status))
        return reply.status == .success
    }

    func finalizeSafety(_ result: ConversionResult) -> ConversionResult {
        guard request.safetyLedger != nil else { return result }
        safety.recordCleanup {
            guard self.cleanupAllowed, let expected = self.cleanupState, let current = self.context?.readState(),
                  self.safety.textMatches(current.text, expected.text), current.selection == expected.selection,
                  self.cleanupAllowed else { return false }
            return true
        }
        // Внешний validity callback может закрыть ledger; последнее решение после него должно быть чистым.
        if case .success = result { return valid && safety.permitsReceipt ? result : .failed }
        if let ledger = request.safetyLedger,
           ledger.hasEditorMutation || ledger.hasUnresolvedSubmissions || ledger.encounteredUnknown { return .failed }
        return result
    }

    func noteCleanupState(_ state: ClipboardEnvironment.TextState) {
        if request.safetyLedger != nil { cleanupState = state }
    }
}
