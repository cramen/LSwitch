import Foundation

extension Converter {
    func makeDiagnostics(
        bundleID: String?, triggerTimestamp: UInt64?, automatic: Bool
    ) -> ConversionDiagnostics {
        let key = bundleID ?? "unknown"
        let attempt = (diagnosticAttempts[key] ?? 0) + 1
        diagnosticAttempts[key] = attempt
        return ConversionDiagnostics(
            bundleID: bundleID, triggerTimestamp: triggerTimestamp, attempt: attempt, automatic: automatic
        )
    }

    func captureCheck(diagnostics: ConversionDiagnostics) -> ContextCheck? {
        if let captureContext { return captureContext() }
        guard let target = InputSafety.captureTarget(diagnostics: diagnostics) else { return nil }
        return { target.isCurrent(diagnostics: diagnostics) }
    }
}
