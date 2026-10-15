import Foundation

extension ClipboardTransaction {
    var usesKeyboardSelection: Bool { context?.selectionMethod == .keyboard }

    func prepareKeyboardSelection(_ plan: AXReplacementPlan) -> Bool {
        guard usesKeyboardSelection else { return true }
        guard KeyboardSelectionPlan.inverse(of: plan) != nil else { return reject(.keyboardUndoUnavailable) }
        guard !plan.wasSelection else { return true }
        guard plan.selection.location == plan.text.utf16.count else {
            return reject(.keyboardSelectionRequiresDocumentEnd)
        }
        guard let keyboardPlan = KeyboardSelectionPlan(
            text: plan.text, selection: plan.selection, target: plan.range
        ) else { return reject(.keyboardSelectionUnavailable) }
        keyboardSelectionPlan = keyboardPlan
        return true
    }

    func applyVerifiedSelection(_ plan: AXReplacementPlan) async -> Bool {
        guard usesKeyboardSelection else { return setSelection(plan.range, cleanup: false) }
        guard let keyboardSelectionPlan else { return false }
        request.diagnostics?.mark(.selectionKeyboardRequested)
        return await send(.selectCharacters(keyboardSelectionPlan.characterCount))
    }

    func restoreKeyboardSelection(_ plan: AXReplacementPlan) async -> Bool {
        guard let keyboardSelectionPlan, plan.selection.location == plan.text.utf16.count,
              recognizedKeyboardState(plan) != nil else { return false }
        // В конце текста Right идемпотентен даже при ignored batch. Обязательно
        // публикуем его после стрелок, не считая cached empty readback их ACK.
        guard await dispatch(.collapseSelection, isValid: { self.recognizedKeyboardState(plan) != nil }) else {
            return false
        }
        return await settleSelection(
            text: plan.text, selection: plan.selection, allowed: keyboardSelectionPlan.ownedRanges, cleanup: true
        )
    }

    func collapseKeyboardSelection(
        _ state: ClipboardEnvironment.TextState, caret: NSRange, allowed: [NSRange]
    ) async -> Bool {
        guard cleanupAllowed, state.selection.length > 0,
              let current = context?.readState(), safety.textMatches(current.text, state.text),
              current.selection == state.selection, cleanupAllowed else { return false }
        guard await dispatch(.collapseSelection, isValid: { self.cleanupAllowed }) else { return false }
        return await settleSelection(text: state.text, selection: caret, allowed: allowed, cleanup: true)
    }

    private func recognizedKeyboardState(_ plan: AXReplacementPlan) -> ClipboardEnvironment.TextState? {
        guard cleanupAllowed, let keyboardSelectionPlan, let current = context?.readState(),
              safety.textMatches(current.text, plan.text),
              keyboardSelectionPlan.ownedRanges.contains(current.selection),
              cleanupAllowed else { return nil }
        return current
    }
}
