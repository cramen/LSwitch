import Foundation

extension Converter {
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
