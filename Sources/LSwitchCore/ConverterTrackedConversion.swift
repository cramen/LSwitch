import Foundation

private struct TrackedConversionPlan {
    let request: ConversionRequest
    let undo: UndoRecord?
}

struct TrackedEngineResult {
    let result: ConversionResult
    let mechanism: ConversionDiagnostics.Mechanism
}

private struct TrackedLayoutResult {
    let confirmed: Bool
    let correction: ConversionRecoveryLayoutTransition?
}

extension Converter {
    func trackedConversion(
        expectedWord: String?, trailingText: String, allowUndo: Bool, context: ConversionRecoveryContext,
        session: ConversionRecoverySession, diagnostics: ConversionDiagnostics
    ) async -> Outcome {
        diagnostics.mark(.holdAcquired)
        await session.drainPendingInput()
        diagnostics.mark(.pendingInputDrained)
        guard session.isValid, let plan = trackedPlan(
            expectedWord: expectedWord, trailingText: trailingText, allowUndo: allowUndo,
            context: context, session: session, diagnostics: diagnostics
        ) else { return finishTrackedFailure(.blocked, context: context, session: session, diagnostics: diagnostics) }
        let routed = await performTracked(plan.request, bundleID: context.bundleID, session: session)
        guard case .success(let receipt) = routed.result else {
            return finishTrackedFailure(routed.result, context: context, session: session, diagnostics: diagnostics)
        }
        guard plan.request.isValid(), receipt.targetIsCurrent?() != false,
              plan.undo.map({ receipt.converted.utf16.elementsEqual($0.original.utf16) }) ?? true else {
            session.retainIfUnfinished()
            return .recoveryRequired
        }
        guard let prepared = session.prepareFinalization(
            text: .confirmed, ordinaryRouteValid: context.isCurrent()
        ) else {
            return .recoveryRequired
        }
        diagnostics.mark(.textConfirmed)
        let target = plan.undo?.layoutBefore
            ?? plan.request.targetLayout(for: receipt.original) ?? context.sourceLayout.opposite
        diagnostics.recordLayoutDecision(source: context.sourceLayout, target: target, receipt: receipt)
        guard let layout = trackedLayout(target: target, context: context, session: session,
                                         prepared: prepared, diagnostics: diagnostics) else {
            session.retainIfUnfinished()
            return .recoveryRequired
        }
        guard session.commitOrdinary(prepared, correction: layout.correction) == .ordinaryTransferred else {
            return .recoveryRequired
        }
        // Ни cache, ни новый receipt, ни успех не публикуются до принятия transport-ом очереди.
        cacheTrackedMode(routed.mechanism, bundleID: context.bundleID)
        if plan.undo != nil { return layout.confirmed ? .undone : .partiallyUndone(targetLayout: target) }
        undoStore.save(.init(original: receipt.original, converted: receipt.converted,
                            layoutBefore: context.sourceLayout, timestamp: Date(), trailingText: receipt.trailingText,
                            bundleID: context.bundleID))
        undoDocumentTarget = receipt.targetIsCurrent
        undoContext = { context.isCurrent() && receipt.targetIsCurrent?() != false }
        guard layout.confirmed else {
            return .partiallyConverted(original: receipt.original, converted: receipt.converted, targetLayout: target)
        }
        onConverted()
        return .converted(original: receipt.original, converted: receipt.converted)
    }

    private func trackedPlan(
        expectedWord: String?, trailingText: String, allowUndo: Bool, context: ConversionRecoveryContext,
        session: ConversionRecoverySession, diagnostics: ConversionDiagnostics
    ) -> TrackedConversionPlan? {
        let undo = allowUndo ? undoStore.pendingUndo() : nil
        let previousTarget = undoDocumentTarget
        if let undo {
            let valid = undo.bundleID == context.bundleID && undoContext?() == true
            undoStore.invalidate()
            undoContext = nil
            undoDocumentTarget = nil
            guard valid else { diagnostics.reject(.contextChanged); return nil }
        }
        let request = ConversionRequest(
            expectedWord: undo?.converted ?? expectedWord, trailingText: undo?.trailingText ?? trailingText,
            replacement: undo?.original, sourceLayout: undo == nil ? context.sourceLayout : nil,
            useSelection: undo == nil && allowUndo, diagnostics: diagnostics, safetyLedger: session.ledger,
            beginMutation: { session.beginMutation() }, canCleanup: { session.canCleanup },
            isValid: { session.isValid }
        )
        return .init(request: undo == nil ? request : request.checkingTarget(previousTarget), undo: undo)
    }

    private func finishTrackedFailure(
        _ result: ConversionResult, context: ConversionRecoveryContext, session: ConversionRecoverySession,
        diagnostics: ConversionDiagnostics
    ) -> Outcome {
        let outcome = outcome(for: result, diagnostics: diagnostics)
        let text: ConversionSafetyTextEvidence = session.ledger.submissionCount == 0 ? .unchangedByOperation : .unknown
        guard let prepared = session.prepareFinalization(text: text, ordinaryRouteValid: context.isCurrent()),
              session.commitOrdinary(prepared, correction: nil) == .ordinaryTransferred else {
            return .recoveryRequired
        }
        return outcome
    }

    private func trackedLayout(
        target: Layout, context: ConversionRecoveryContext, session: ConversionRecoverySession,
        prepared: ConversionRecoveryPreparation, diagnostics: ConversionDiagnostics
    ) -> TrackedLayoutResult? {
        if target == context.sourceLayout {
            let observed = currentLayout()
            diagnostics.recordLayoutObservation(stage: .alreadyTarget, accepted: nil, observed: observed)
            guard session.permitsFinalEffects(prepared) else { return nil }
            if observed == target { diagnostics.mark(.layoutConfirmed); return .init(confirmed: true, correction: nil) }
        } else if !session.permitsFinalEffects(prepared) { return nil }
        let accepted = switchLayout(target)
        diagnostics.recordLayoutObservation(stage: .adapter, accepted: accepted, observed: nil)
        guard accepted else {
            diagnostics.reject(.layoutNotConfirmed)
            return .init(confirmed: false, correction: nil)
        }
        let observed = currentLayout()
        diagnostics.recordLayoutObservation(stage: .readback, accepted: accepted, observed: observed)
        guard observed == target else {
            diagnostics.reject(.layoutNotConfirmed)
            return .init(confirmed: false, correction: nil)
        }
        diagnostics.mark(.layoutConfirmed)
        let correction = context.sourceLayout == target ? nil : ConversionRecoveryLayoutTransition(
            source: context.sourceLayout, target: target, startedAt: context.startedAt,
            completedAt: DispatchTime.now().uptimeNanoseconds
        )
        return .init(confirmed: true, correction: correction)
    }
}
