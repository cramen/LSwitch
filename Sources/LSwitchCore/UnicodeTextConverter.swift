import Foundation

/// Один upfront-движок: после попытки выделения или Down другой путь запрещён.
@MainActor
public final class UnicodeTextConverter: ConversionEngine {
    private let environment: UnicodeEnvironment

    public convenience init() {
        self.init(environment: .live())
    }

    init(environment: UnicodeEnvironment) {
        self.environment = environment
    }

    public func perform(_ request: ConversionRequest) async -> ConversionResult {
        #if DEBUG
        return await UnicodePerformance.profile { await execute(request) }
        #else
        return await execute(request)
        #endif
    }

    private func execute(_ request: ConversionRequest) async -> ConversionResult {
        guard let captured = capture(request) else {
            UnicodeMutationSafety(request: request).recordCleanup(validateFresh: { false })
            return .blocked
        }
        let safety = UnicodeMutationSafety(request: captured.request)
        guard safety.bind(target: captured.receiverTarget, contract: environment.receiverContract),
              let transaction = prepare(captured, safety: safety) else {
            safety.recordCleanup(validateFresh: { false })
            return .blocked
        }
        let result = await transaction.run()
        if case .success(let receipt) = result { return .success(receipt.checkingTarget(captured.targetCheck)) }
        return result
    }

    private func capture(_ request: ConversionRequest) -> UnicodeReadBoundary? {
        guard !Task.isCancelled, request.isValid(), let context = environment.captureContext() else {
            request.diagnostics?.reject(.contextUnavailable)
            return nil
        }
        guard environment.canPost() else {
            request.diagnostics?.reject(.engineUnavailable)
            return nil
        }
        guard let source = environment.activeSource() else {
            request.diagnostics?.reject(.unicodeInputSourceUnsupported)
            return nil
        }
        return UnicodeReadBoundary.capture(
            context: context, request: request, source: source, activeSource: environment.activeSource
        )
    }

    private func prepare(_ captured: UnicodeReadBoundary, safety: UnicodeMutationSafety) -> UnicodeTransaction? {
        let request = captured.request
        guard let snapshot = captured.read() else { return nil }
        guard let plan = AXReplacementPlan(
            text: snapshot.text, selection: snapshot.selection, request: request, transform: request.converted
        ) else {
            request.diagnostics?.reject(.expectedSpanMismatch)
            return nil
        }
        guard request.permitsAutomaticContext(captured.automatic, plan: plan) else { return nil }
        guard plan.text != plan.resultingText, UnicodePacketPolicy.permits(plan.replacement),
              UnicodePacketPolicy.permits(plan.receipt.original + plan.receipt.trailingText),
              UnicodePacketPolicy.permitsSelection(in: plan.text, range: plan.range) else {
            request.diagnostics?.reject(.unicodePayloadUnsupported)
            return nil
        }
        let keyboardPlan = KeyboardSelectionPlan(text: plan.text, selection: plan.selection, target: plan.range)
        if !plan.wasSelection, keyboardPlan == nil {
            let reason: ConversionDiagnostics.Rejection = plan.selection.location != plan.text.utf16.count
                ? .keyboardSelectionRequiresDocumentEnd : .keyboardSelectionUnavailable
            request.diagnostics?.reject(reason)
            return nil
        }
        guard KeyboardSelectionPlan.inverse(of: plan) != nil else {
            request.diagnostics?.reject(.keyboardUndoUnavailable)
            return nil
        }
        guard let packet = environment.prepare(plan.replacement, captured.processID) else {
            request.diagnostics?.reject(.unicodePreparationFailed)
            return nil
        }
        if request.safetyLedger != nil, packet.postTracked == nil || environment.sendSelectionTracked == nil {
            request.diagnostics?.reject(.unicodePreparationFailed)
            return nil
        }
        return UnicodeTransaction(
            environment: environment, boundary: captured,
            plan: plan, keyboardPlan: keyboardPlan, prepared: .init(packet: packet, safety: safety)
        )
    }
}
