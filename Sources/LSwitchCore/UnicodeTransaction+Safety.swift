import Foundation

extension UnicodeTransaction {
    func sendSelection(
        _ command: NativeSelectionCommand,
        before: @escaping @MainActor () -> Bool, after: @escaping @MainActor () -> Bool,
        cleanup: Bool = false
    ) async -> Bool {
        let current = {
            (cleanup ? self.boundary.canCleanup : self.valid) && self.environment.canPost()
        }
        guard let hooks = safety.hooks(isValid: current) else {
            return await environment.sendSelection(command, boundary.processID, before, after)
        }
        return await environment.sendSelectionTracked?(command, boundary.processID, before, after, hooks) == true
    }

    func postPacket(isValid: @escaping @MainActor () -> Bool) -> Bool {
        guard let hooks = safety.hooks(isValid: { self.valid && self.environment.canPost() }) else {
            return packet.post(isValid)
        }
        _ = packet.postTracked?(isValid, hooks)
        return safety.submittedText
    }

    func finalizeSafety(_ result: ConversionResult) -> ConversionResult {
        guard let ledger = request.safetyLedger else { return result }
        safety.recordCleanup {
            guard let expected = self.cleanupState, let snapshot = self.read(cleanup: true) else { return false }
            return snapshot.matches(text: expected.text, selection: expected.selection)
        }
        // Внешний validity callback может закрыть ledger; последнее решение после него должно быть чистым.
        if case .success = result { return valid && safety.permitsReceipt ? result : .failed }
        let unsafe = ledger.hasEditorMutation || ledger.hasUnresolvedSubmissions || ledger.encounteredUnknown
        return unsafe ? .failed : result
    }
}
