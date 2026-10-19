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
        let context: ContextCheck
        if let captureContext {
            guard let captured = captureContext() else { return nil }
            context = captured
        } else {
            guard let target = InputSafety.captureTarget(diagnostics: diagnostics) else { return nil }
            context = { target.isCurrent(diagnostics: diagnostics) }
        }
        let profiles = localProfiles
        let revision = profiles?.revision
        return { profiles?.revision == revision && context() && profiles?.revision == revision }
    }
}
