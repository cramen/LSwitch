#if DEBUG
import Foundation

/// Concrete weak scope читается после внешних callbacks без повторного вызова host safety.
@MainActor
final class TextEditRecoveryValidationScope {
    private weak var runtime: TextEditRecoveryRuntime?
    private weak var attempt: TextEditRecoveryAttempt?

    init(runtime: TextEditRecoveryRuntime, attempt: TextEditRecoveryAttempt) {
        self.runtime = runtime
        self.attempt = attempt
    }

    var isCurrent: Bool {
        guard let runtime, let attempt else { return false }
        return runtime.attempt === attempt && attempt.interruption == nil && !attempt.invocationFinished
            && !attempt.finishing && !runtime.quitAuthorized
    }
}
#endif
