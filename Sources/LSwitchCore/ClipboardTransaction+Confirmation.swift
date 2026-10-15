import Foundation
import os

extension ClipboardTransaction {
    func confirmPaste(expectation: PasteExpectation?, original: String, inserted: String) async -> Bool {
        guard let expectation else { return await confirmWithoutState(original: original, inserted: inserted) }
        for attempt in 0...3 {
            guard valid else {
                await cleanupPaste(expectation: expectation, original: original, inserted: inserted)
                return false
            }
            if let state = context?.readState(), await acknowledge(state, expectation: expectation) { return true }
            if attempt < 3 { await environment.sleep(configuration.writeDelay) }
        }
        await cleanupPaste(expectation: expectation, original: original, inserted: inserted)
        return false
    }

    func confirmWithoutState(original: String, inserted: String) async -> Bool {
        logger.info("Clipboard: подтверждение без полного AX-состояния")
        await environment.sleep(configuration.postPasteDelay)
        guard valid else {
            await cleanupPaste(expectation: nil, original: original, inserted: inserted)
            return false
        }
        guard let remaining = context?.selectedText(), !remaining.isEmpty else {
            logger.notice("Clipboard: вставка не подтверждена, нет доступного AX-свидетельства")
            return false
        }
        guard remaining == original || remaining == inserted else { return false }
        guard await collapseSelection() else { return false }
        return valid && remaining == inserted
    }

    func acknowledge(_ state: ClipboardEnvironment.TextState, expectation: PasteExpectation) async -> Bool {
        guard valid else { return false }
        if expectation.isConfirmed(state), safety.textMatches(state.text, expectation.expectedText) {
            noteCleanupState(state)
            return safety.requireCompletion(.textConfirmed)
        }
        guard safety.textMatches(state.text, expectation.expectedText),
              state.selection == expectation.insertedRange else { return false }
        if await collapseKnownSelection(state) { return valid }
        guard verifiedPlan == nil, await collapseSelection(), valid,
              let collapsed = context?.readState() else { return false }
        return expectation.isConfirmed(collapsed) && safety.textMatches(collapsed.text, expectation.expectedText)
    }

    func collapseKnownSelection(_ state: ClipboardEnvironment.TextState) async -> Bool {
        guard cleanupAllowed, let current = context?.readState(),
              safety.textMatches(current.text, state.text), current.selection == state.selection else { return false }
        let caret = NSRange(location: NSMaxRange(state.selection), length: 0)
        guard cleanupAllowed else { return false }
        if usesKeyboardSelection {
            return await collapseKeyboardSelection(state, caret: caret, allowed: [state.selection, caret])
        }
        _ = setSelection(caret, cleanup: true)
        return await settleSelection(
            text: state.text, selection: caret, allowed: [state.selection, caret], cleanup: true
        )
    }

    func cleanupPaste(expectation: PasteExpectation?, original: String, inserted: String) async {
        guard cleanupAllowed else { return }
        if let expectation {
            guard let state = context?.readState(), state.selection.length > 0,
                  recognizesCleanupSelection(state, expectation: expectation) else { return }
            if let verifiedPlan {
                if safety.textMatches(state.text, verifiedPlan.text) {
                    await restoreVerifiedSelection(verifiedPlan)
                } else {
                    _ = await collapseKnownSelection(state)
                }
                return
            }
        } else {
            guard let selected = context?.selectedText(), !selected.isEmpty,
                  selected == original || selected == inserted else { return }
        }
        _ = await collapseSelection()
    }

    private func recognizesCleanupSelection(
        _ state: ClipboardEnvironment.TextState, expectation: PasteExpectation
    ) -> Bool {
        let original = safety.textMatches(state.text, expectation.before.text)
            && state.selection == expectation.before.selection
        let converted = safety.textMatches(state.text, expectation.expectedText)
            && state.selection == expectation.insertedRange
        return original || converted
    }

    func cleanupLegacySelection() async -> Bool {
        guard cleanupAllowed else { return false }
        if request.safetyLedger != nil {
            if let verifiedPlan {
                await restoreVerifiedSelection(verifiedPlan)
                return cleanupState != nil
            }
            guard let state = context?.readState(), let legacyState,
                  safety.textMatches(state.text, legacyState.text), state.selection == legacyState.selection else {
                return false
            }
            return await collapseKnownSelection(state)
        }
        if let state = context?.readState(), let legacyState,
           state.text == legacyState.text, state.selection == legacyState.selection, state.selection.length > 0 {
            return await collapseSelection()
        }
        if context?.selectedText()?.isEmpty == true { return true }
        guard let selected = context?.selectedText(), !selected.isEmpty else { return false }
        let matchesExpected = request.expectedWord != nil && request.matchingParts(in: selected) != nil
        guard matchesExpected || selected == legacySelection else { return false }
        return await collapseSelection()
    }
}
