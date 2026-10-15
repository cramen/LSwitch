import Foundation

extension KeyboardSelectionPlan {
    /// Прямое готовое выделение не доказывает возможность повторно выделить результат для undo.
    static func inverse(of plan: AXReplacementPlan) -> KeyboardSelectionPlan? {
        let request = ConversionRequest(
            expectedWord: plan.receipt.converted, trailingText: plan.receipt.trailingText,
            replacement: plan.receipt.original, useSelection: false
        )
        guard let inverse = AXReplacementPlan(
            text: plan.resultingText, selection: plan.finalSelection,
            request: request, transform: request.converted
        ), inverse.resultingText.utf16.elementsEqual(plan.text.utf16),
           inverse.finalSelection == NSRange(location: NSMaxRange(plan.range), length: 0) else { return nil }
        return KeyboardSelectionPlan(text: inverse.text, selection: inverse.selection, target: inverse.range)
    }
}
