import Foundation
import os

extension ClipboardTransaction {
    func captureClipboard() -> Bool {
        guard valid else { return false }
        initialCount = environment.changeCount()
        snapshot = environment.capture()
        return valid && initialCount == environment.changeCount()
    }

    func performVerified(_ plan: AXReplacementPlan) async -> ConversionResult {
        verifiedPlan = plan
        guard captureClipboard() else { return .blocked }
        let written = environment.write(plan.replacement)
        ownedCount = written.changeCount
        guard written.succeeded else { return .unavailable }
        guard originalStateMatches(plan) else { return .blocked }
        let outcome = environment.commitPaste(
            { self.selectVerified(plan) },
            { self.selectedStateMatches(plan) },
            { self.valid && self.environment.changeCount() == self.ownedCount }
        )
        return await completeVerified(outcome, plan: plan)
    }

    func originalStateMatches(_ plan: AXReplacementPlan) -> Bool {
        guard valid, environment.changeCount() == ownedCount, let current = context?.readState() else { return false }
        return current.text == plan.text && current.selection == plan.selection && valid &&
            environment.changeCount() == ownedCount
    }

    func selectVerified(_ plan: AXReplacementPlan) -> Bool {
        guard originalStateMatches(plan) else {
            logger.notice("clipboard phase=select-preflight matched=false")
            return false
        }
        guard beginMutationIfValid() else {
            mutationDenied = true
            logger.notice("clipboard phase=select-begin allowed=false")
            return false
        }
        guard !plan.wasSelection else {
            logger.info("clipboard phase=select existingSelection=true")
            return true
        }
        createdSelection = true
        let applied = context?.setSelection(plan.range) == true
        // AX может применить ограниченный диапазон даже при ошибке. Запоминаем
        // фактически прочитанный результат; позже не трогаем изменившееся выделение.
        if cleanupAllowed, let observed = context?.readState(), observed.text == plan.text {
            observedSelection = observed.selection
        }
        let contextValid = valid
        logger.notice("phase=select applied=\(applied, privacy: .public) valid=\(contextValid, privacy: .public)")
        return applied && contextValid
    }

    func selectedStateMatches(_ plan: AXReplacementPlan) -> Bool {
        guard valid else {
            logger.notice("clipboard phase=selection-check context=false")
            return false
        }
        guard environment.changeCount() == ownedCount else {
            logger.notice("clipboard phase=selection-check context=true clipboard=false")
            return false
        }
        guard let selected = context?.readState() else {
            logger.notice("clipboard phase=selection-check snapshot=false")
            return false
        }
        let textMatches = selected.text == plan.text
        let rangeMatches = selected.selection == plan.range
        let contextValid = valid
        let clipboardMatches = environment.changeCount() == ownedCount
        logger.notice("selection-check text=\(textMatches, privacy: .public) range=\(rangeMatches, privacy: .public)")
        logger.notice("phase=selection-check context=\(contextValid, privacy: .public)")
        logger.notice("phase=selection-check clipboard=\(clipboardMatches, privacy: .public)")
        return textMatches && rangeMatches && contextValid && clipboardMatches
    }

    func restoreVerifiedSelection(_ plan: AXReplacementPlan) {
        guard createdSelection, !plan.wasSelection, cleanupAllowed, let observedSelection,
              observedSelection != plan.selection, let current = context?.readState(),
              current.text == plan.text, current.selection == observedSelection, cleanupAllowed else { return }
        _ = context?.setSelection(plan.selection)
    }

    func cleanupVerifiedFailure(_ plan: AXReplacementPlan) {
        guard cleanupAllowed, let current = context?.readState() else { return }
        let inserted = NSRange(location: plan.range.location, length: plan.replacement.utf16.count)
        if current.text == plan.resultingText && current.selection == inserted {
            _ = collapseKnownSelection(current)
        } else {
            restoreVerifiedSelection(plan)
        }
    }

    func completeVerified(_ outcome: MenuCommand.Outcome, plan: AXReplacementPlan) async -> ConversionResult {
        switch outcome {
        case .unavailable:
            logger.notice("Clipboard отказ до выделения: нет синхронной команды Paste")
            return .unavailable
        case .failed:
            guard !mutationDenied else { return .blocked }
            pasted = true
            cleanupVerifiedFailure(plan)
            return .failed
        case .performed:
            pasted = true
        }
        let expectation = PasteExpectation(
            before: (plan.text, plan.range), expectedText: plan.resultingText,
            insertedRange: NSRange(location: plan.range.location, length: plan.replacement.utf16.count)
        )
        let span = plan.receipt.original + plan.receipt.trailingText
        guard await confirmPaste(expectation: expectation, original: span, inserted: plan.replacement) else {
            return .failed
        }
        logger.info("Clipboard-конвертация завершена через AX-выделение и native Paste")
        return .success(plan.receipt)
    }
}
