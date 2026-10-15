import Foundation

extension ConversionRequest {
    /// Identity ограничивает цель записи, не применяя lexical policy к ручной команде.
    func checkingTarget(_ check: ConversionReceipt.TargetCheck?) -> ConversionRequest {
        guard let check else { return self }
        return ConversionRequest(
            expectedWord: expectedWord, trailingText: trailingText, replacement: replacement,
            sourceLayout: sourceLayout, useSelection: useSelection, diagnostics: diagnostics,
            beginMutation: beginMutation, canCleanup: { canCleanup() && check() },
            isValid: {
                guard isValid() else { return false }
                return check() || (diagnostics?.reject(.documentChanged) ?? false)
            }
        )
    }
}

extension ConversionReceipt {
    func checkingTarget(_ check: TargetCheck?) -> ConversionReceipt {
        ConversionReceipt(original: original, converted: converted, trailingText: trailingText, targetIsCurrent: check)
    }
}

extension AutomaticTextContext {
    var documentIdentity: String? {
        switch self {
        case .documentProse(let document), .source(_, let document, _), .unverifiedSource(let document): return document
        case .prose, .unknown: return nil
        }
    }
}

@MainActor
enum ConversionDocumentTarget {
    static func check(
        identity: String?, read: @escaping @MainActor @Sendable () -> String?
    ) -> ConversionReceipt.TargetCheck? {
        guard let identity else { return nil }
        return { read() == identity }
    }
}
