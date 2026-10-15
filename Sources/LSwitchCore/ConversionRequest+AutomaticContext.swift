import Foundation

extension ConversionRequest {
    var isAutomatic: Bool { !useSelection && replacement == nil }

    @MainActor
    func permitsAutomaticContext(_ context: AutomaticTextContext, plan: AXReplacementPlan) -> Bool {
        guard isAutomatic else { return true }
        if case .unverifiedSource = context {
            diagnostics?.reject(.sourceSnapshotUnverified)
            return false
        }
        let wordRange = NSRange(location: plan.range.location, length: plan.receipt.original.utf16.count)
        let region = AutomaticTextPolicy.region(text: plan.text, wordRange: wordRange, context: context)
        guard region.allowsCorrection else {
            diagnostics?.reject(region == .code ? .sourceCode : .sourceContextUnknown)
            return false
        }
        return true
    }

    /// Разрешение связано с документом на всё время await, cleanup также не затрагивает другую вкладку.
    func checkingDocumentContext(
        _ expected: AutomaticTextContext,
        read: @escaping @MainActor @Sendable () -> AutomaticTextContext
    ) -> ConversionRequest {
        guard isAutomatic, expected != .prose else { return self }
        return ConversionRequest(
            expectedWord: expectedWord, trailingText: trailingText, replacement: replacement,
            sourceLayout: sourceLayout, useSelection: useSelection, diagnostics: diagnostics,
            safetyLedger: safetyLedger,
            beginMutation: beginMutation,
            canCleanup: { canCleanup() && read() == expected },
            isValid: {
                guard isValid() else { return false }
                guard read() == expected else {
                    diagnostics?.reject(.sourceDocumentChanged)
                    return false
                }
                return true
            }
        )
    }
}
