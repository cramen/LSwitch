import Foundation
import os

extension ClipboardTransaction {
    /// Сначала связываем документ, затем читаем текст. Readback проверяет тот же identity.
    func prepareAutomaticSnapshot() -> Bool {
        guard request.isAutomatic else { return true }
        guard valid else { return false }
        if automaticContext == nil {
            automaticContext = context?.automaticContext() ?? .unknown
            if let context {
                documentTargetCheck = ConversionDocumentTarget.check(identity: automaticContext?.documentIdentity,
                                                                    read: context.documentIdentity)
            }
        }
        return valid
    }

    func captureClipboard() async -> Bool {
        guard valid else { return false }
        request.diagnostics?.mark(.clipboardCaptureStarted)
        initialCount = environment.changeCount()
        let result = await environment.capture()
        guard acceptCapture(result) else { return false }
        request.diagnostics?.mark(.clipboardCaptured)
        guard valid else { return false }
        guard initialCount == environment.changeCount() else { return reject(.clipboardChanged) }
        guard snapshot?.isRestorable == true else { return reject(.clipboardNotRestorable) }
        return true
    }

    private func acceptCapture(_ result: PasteboardCaptureResult) -> Bool {
        switch result {
        case .captured(let captured, let count):
            guard count == initialCount else { return reject(.clipboardChanged) }
            snapshot = captured
        case .changed: return reject(.clipboardChanged)
        case .timedOut: return reject(.clipboardCaptureTimedOut)
        case .cancelled: return reject(.cancelled)
        case .busy: return reject(.clipboardCaptureBusy)
        case .unavailable: return reject(.clipboardCaptureUnavailable)
        }
        return true
    }

    func writeClipboard(_ text: String) -> (succeeded: Bool, changeCount: Int) {
        request.diagnostics?.mark(.clipboardWriteStarted)
        lastWriteOwnedCount = nil
        let result: (succeeded: Bool, changeCount: Int)
        if request.safetyLedger != nil {
            guard let written = environment.writeTracked?(text, {
                self.valid && self.safety.permitsOrdinary
                    && self.environment.changeCount() == (self.ownedCount ?? self.initialCount)
            }) else { return (false, ownedCount ?? initialCount) }
            result = written
        } else {
            result = environment.write(text)
        }
        lastWriteOwnedCount = result.changeCount
        request.diagnostics?.mark(.clipboardWritten)
        return result
    }

    func performVerified(_ plan: AXReplacementPlan) async -> ConversionResult {
        if request.isAutomatic {
            guard valid else { return .blocked }
            let current = automaticContext ?? .unknown
            guard context?.automaticContext() == current else { return .blocked }
            guard request.permitsAutomaticContext(current, plan: plan), valid else { return .blocked }
        }
        guard prepareKeyboardSelection(plan) else { return .blocked }
        verifiedPlan = plan
        guard await captureClipboard() else { return .blocked }
        let written = writeClipboard(plan.replacement)
        ownedCount = lastWriteOwnedCount ?? ownedCount
        guard written.succeeded else {
            reject(.clipboardWriteFailed)
            return .unavailable
        }
        guard originalStateMatches(plan) else { return .blocked }
        request.diagnostics?.mark(.pasteRequested)
        let outcome = await commitVerifiedPaste(plan)
        return await completeVerified(outcome, plan: plan)
    }

    func originalStateMatches(_ plan: AXReplacementPlan) -> Bool {
        guard valid else { return false }
        guard environment.changeCount() == ownedCount else { return reject(.clipboardChanged) }
        guard let current = context?.readState() else { return reject(.snapshotUnavailable) }
        guard safety.textMatches(current.text, plan.text) else { return reject(.textChanged) }
        guard current.selection == plan.selection else { return reject(.selectionChanged) }
        guard valid else { return false }
        return environment.changeCount() == ownedCount || reject(.clipboardChanged)
    }

    func selectVerified(_ plan: AXReplacementPlan) async -> Bool {
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
        let applied = await applyVerifiedSelection(plan)
        if applied { request.diagnostics?.mark(.selectionApplied) }
        if cleanupAllowed, let observed = context?.readState(), safety.textMatches(observed.text, plan.text),
           observed.selection.location == plan.range.location,
           NSMaxRange(observed.selection) <= NSMaxRange(plan.range) {
            observedSelection = observed.selection
        }
        guard applied else { return reject(.selectionFailed) }
        let settled = await settleSelection(
            text: plan.text, selection: plan.range, allowed: ownedRanges(plan), cleanup: false
        )
        if settled { request.diagnostics?.mark(.selectionSettled) }
        logger.notice("phase=select settled=\(settled, privacy: .public)")
        guard settled else { return reject(.selectionChanged) }
        return safety.requireCompletion(.selectionSettled)
    }

    func selectedStateMatches(_ plan: AXReplacementPlan) -> Bool {
        guard valid else {
            logger.notice("clipboard phase=selection-check context=false")
            return false
        }
        guard environment.changeCount() == ownedCount else {
            logger.notice("clipboard phase=selection-check context=true clipboard=false")
            reject(.clipboardChanged)
            return false
        }
        guard let selected = context?.readState() else {
            logger.notice("clipboard phase=selection-check snapshot=false")
            reject(.snapshotUnavailable)
            return false
        }
        let textMatches = safety.textMatches(selected.text, plan.text)
        let rangeMatches = selected.selection == plan.range
        let contextValid = valid
        let clipboardMatches = environment.changeCount() == ownedCount
        logger.notice("selection-check text=\(textMatches, privacy: .public) range=\(rangeMatches, privacy: .public)")
        logger.notice("phase=selection-check context=\(contextValid, privacy: .public)")
        logger.notice("phase=selection-check clipboard=\(clipboardMatches, privacy: .public)")
        guard contextValid else { return false }
        guard textMatches else { return reject(.textChanged) }
        guard rangeMatches else { return reject(.selectionChanged) }
        return clipboardMatches || reject(.clipboardChanged)
    }

    func restoreVerifiedSelection(_ plan: AXReplacementPlan) async {
        guard createdSelection, !plan.wasSelection else { return }
        if let ledger = request.safetyLedger, !ledger.hasEditorMutation { return }
        if keyboardSelectionPlan != nil {
            let settled = await restoreKeyboardSelection(plan)
            logger.notice("phase=selection-cleanup native=true settled=\(settled, privacy: .public)")
            return
        }
        guard cleanupAllowed,
              let current = context?.readState(), safety.textMatches(current.text, plan.text),
              ownedRanges(plan).contains(current.selection),
              cleanupAllowed else { return }
        // Всегда отменяем собственную попытку: ранний readback исходной каретки
        // не доказывает, что отложенный setter уже завершился.
        _ = setSelection(plan.selection, cleanup: true)
        let settled = await settleSelection(
            text: plan.text, selection: plan.selection, allowed: ownedRanges(plan), cleanup: true
        )
        logger.notice("phase=selection-cleanup settled=\(settled, privacy: .public)")
    }

    private func ownedRanges(_ plan: AXReplacementPlan) -> [NSRange] {
        if let keyboardSelectionPlan { return keyboardSelectionPlan.ownedRanges }
        return [plan.selection, plan.range] + (observedSelection.map { [$0] } ?? [])
    }

    func settleSelection(text: String, selection: NSRange, allowed: [NSRange], cleanup: Bool) async -> Bool {
        let settled = await SelectionSettlement.wait(
            expected: (text, selection), allowedSelections: allowed,
            isValid: {
                if cleanup { return self.cleanupAllowed }
                return self.valid && self.environment.changeCount() == self.ownedCount
            },
            read: {
                guard let state = self.context?.readState(),
                      self.safety.textMatches(state.text, text) else { return nil }
                return state
            },
            pause: {
                if let pause = self.environment.settlementPause {
                    await pause()
                } else {
                    await self.environment.sleep(self.configuration.writeDelay)
                }
            }
        )
        if settled, cleanup { noteCleanupState((text, selection)) }
        return settled
    }

    func cleanupVerifiedFailure(_ plan: AXReplacementPlan) async {
        guard cleanupAllowed, let current = context?.readState() else { return }
        let inserted = NSRange(location: plan.range.location, length: plan.replacement.utf16.count)
        if safety.textMatches(current.text, plan.resultingText) && current.selection == inserted {
            _ = await collapseKnownSelection(current)
        } else {
            await restoreVerifiedSelection(plan)
        }
    }

    func completeVerified(_ outcome: MenuCommand.Outcome, plan: AXReplacementPlan) async -> ConversionResult {
        switch outcome {
        case .unavailable:
            logger.notice("Clipboard отказ до выделения: нет синхронной команды Paste")
            reject(.engineUnavailable)
            return .unavailable
        case .failed:
            guard !mutationDenied else { return .blocked }
            if request.safetyLedger == nil { pasted = true }
            await cleanupVerifiedFailure(plan)
            return .failed
        case .performed:
            if request.safetyLedger == nil { pasted = true }
        }
        let expectation = PasteExpectation(
            before: (plan.text, plan.range), expectedText: plan.resultingText,
            insertedRange: NSRange(location: plan.range.location, length: plan.replacement.utf16.count)
        )
        let span = plan.receipt.original + plan.receipt.trailingText
        guard await confirmPaste(expectation: expectation, original: span, inserted: plan.replacement) else {
            return .failed
        }
        logger.info("Clipboard-конвертация завершена через проверенное выделение и native Paste")
        return .success(plan.receipt)
    }
}
