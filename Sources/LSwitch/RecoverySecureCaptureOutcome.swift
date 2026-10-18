#if DEBUG
import Foundation

/// Только наблюдение фиксированной пары после подтверждённого Secure Input, не privacy admission.
enum RecoverySecureCaptureOutcome: String {
    case interceptedDuringSecureInput, deliveredWithoutCapture

    struct Observation {
        let enabled: Bool
        let owned: Bool
        let events: Int
        let bytes: Int
        let reads: Int
        let received: [String]
        let changes: Int
        let fixtureUnchanged: Bool
        let controlMatches: Bool

        var outcome: RecoverySecureCaptureOutcome? {
            guard enabled, owned else { return nil }
            if events == 2, bytes == 16, reads == 2, received.isEmpty, changes == 0, fixtureUnchanged {
                return .interceptedDuringSecureInput
            }
            if events == 0, bytes == 0, reads == 0, received == ["prefixDown", "prefixRelease"],
               changes == 1, controlMatches { return .deliveredWithoutCapture }
            return nil
        }
    }
}
#endif
