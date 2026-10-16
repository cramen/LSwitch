import Foundation

extension Converter {
    /// Автоматический запрос отменён ещё до запуска Task конвертации.
    public func recordSkippedAutomatic(
        triggerTimestamp: UInt64, bundleID: String?, reason: ConversionDiagnostics.Rejection
    ) {
        let diagnostics = makeDiagnostics(bundleID: bundleID, triggerTimestamp: triggerTimestamp, automatic: true)
        diagnostics.reject(reason)
        diagnostics.complete(.skipped)
    }

    public enum Outcome: Equatable {
        case converted(original: String, converted: String)
        case undone
        /// Текст подтверждён, точный undo доступен, но раскладка не подтверждена.
        case partiallyConverted(original: String, converted: String, targetLayout: Layout)
        case partiallyUndone(targetLayout: Layout)
        case blockedByRules, blockedBySafety, unsupportedLayout, busy, failed
        /// Tracked-владелец сохраняет очередь; обычный release/receipt не разрешён.
        case recoveryRequired

        public var label: String {
            switch self {
            case .converted: return "converted"
            case .undone: return "undone"
            case .partiallyConverted: return "partiallyConverted"
            case .partiallyUndone: return "partiallyUndone"
            case .blockedByRules: return "blockedByRules"
            case .blockedBySafety: return "blockedBySafety"
            case .unsupportedLayout: return "unsupportedLayout"
            case .busy: return "busy"
            case .failed: return "failed"
            case .recoveryRequired: return "recoveryRequired"
            }
        }
    }

    func outcome(for result: ConversionResult, diagnostics: ConversionDiagnostics) -> Outcome {
        switch result {
        case .blocked:
            diagnostics.reject(.requestInvalid)
            return .blockedBySafety
        case .unavailable:
            diagnostics.reject(.engineUnavailable)
        case .failed:
            diagnostics.reject(.textNotConfirmed)
        case .success:
            break
        }
        return .failed
    }
}
