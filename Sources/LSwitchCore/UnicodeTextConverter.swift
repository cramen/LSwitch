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

    private struct Captured {
        let context: UnicodeEnvironment.Context
        let request: ConversionRequest
        let source: UnicodeInputSource
        let automatic: AutomaticTextContext
        let targetCheck: ConversionReceipt.TargetCheck
    }

    public func perform(_ request: ConversionRequest) async -> ConversionResult {
        #if DEBUG
        return await UnicodePerformance.profile { await execute(request) }
        #else
        return await execute(request)
        #endif
    }

    private func execute(_ request: ConversionRequest) async -> ConversionResult {
        guard let captured = capture(request), let transaction = prepare(captured) else { return .blocked }
        let result = await transaction.run()
        if case .success(let receipt) = result { return .success(receipt.checkingTarget(captured.targetCheck)) }
        return result
    }

    private func capture(_ request: ConversionRequest) -> Captured? {
        guard !Task.isCancelled, request.isValid(), let context = environment.captureContext(), context.isValid() else {
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
        // Identity захватывается до чтения текста, затем повторяется в scoped guards.
        guard let identity = context.documentIdentity() else {
            request.diagnostics?.reject(.unicodeSnapshotUnverified)
            return nil
        }
        let targetCheck: ConversionReceipt.TargetCheck = {
            context.isValid() && context.documentIdentity() == identity
        }
        let automatic = request.isAutomatic ? context.automaticContext() : .prose
        let scoped = request.checkingTarget(targetCheck).checkingDocumentContext(
            automatic, read: context.automaticContext
        )
        return Captured(context: context, request: scoped, source: source,
                        automatic: automatic, targetCheck: targetCheck)
    }

    private func prepare(_ captured: Captured) -> UnicodeTransaction? {
        let context = captured.context
        let request = captured.request
        guard request.isValid(), context.isValid(), let snapshot = context.snapshot(),
              request.isValid(), context.isValid() else { return nil }
        guard snapshot.isComplete else {
            request.diagnostics?.reject(.unicodeSnapshotUnverified)
            return nil
        }
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
        guard let packet = environment.prepare(plan.replacement, context.processID) else {
            request.diagnostics?.reject(.unicodePreparationFailed)
            return nil
        }
        return UnicodeTransaction(
            environment: environment, context: context, request: request, source: captured.source,
            plan: plan, keyboardPlan: keyboardPlan, packet: packet
        )
    }
}
