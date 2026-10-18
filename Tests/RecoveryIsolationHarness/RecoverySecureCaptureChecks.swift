import Foundation

@MainActor
enum RecoverySecureCaptureChecks {
    static func run() throws {
        let intercepted = evaluate(events: 2, bytes: 16, reads: 2)
        try check(intercepted == .interceptedDuringSecureInput, "capture under Secure is a privacy finding")
        let delivered = RecoverySecureCaptureOutcome.Observation(
            enabled: true, owned: true, events: 0, bytes: 0, reads: 0,
            received: ["prefixDown", "prefixRelease"], changes: 1,
            fixtureUnchanged: false, controlMatches: true).outcome
        try check(delivered == .deliveredWithoutCapture, "no capture requires observed delivery")
        for counts in [(0, 0, 0), (1, 8, 1), (2, 16, 1), (2, 4, 2), (3, 24, 3)] {
            try check(evaluate(events: counts.0, bytes: counts.1, reads: counts.2) == nil,
                      "absence, partial prefix and malformed counts are inconclusive")
        }
        for (enabled, owned) in [(false, true), (true, false)] {
            let expired = RecoverySecureCaptureOutcome.Observation(
                enabled: enabled, owned: owned, events: 2, bytes: 16, reads: 2,
                received: [], changes: 0, fixtureUnchanged: true, controlMatches: false).outcome
            try check(expired == nil, "secure interval must still be observed")
        }
        let duplicated = RecoverySecureCaptureOutcome.Observation(
            enabled: true, owned: true, events: 2, bytes: 16, reads: 2,
            received: ["prefixDown", "prefixRelease"], changes: 1,
            fixtureUnchanged: false, controlMatches: true).outcome
        try check(duplicated == nil, "capture and delivery together are not a clean observation")
    }

    private static func evaluate(events: Int, bytes: Int, reads: Int) -> RecoverySecureCaptureOutcome? {
        RecoverySecureCaptureOutcome.Observation(
            enabled: true, owned: true, events: events, bytes: bytes, reads: reads,
            received: [], changes: 0, fixtureUnchanged: true, controlMatches: false).outcome
    }

    private static func check(_ value: Bool, _ name: String) throws {
        try RecoveryIsolationMatrixChecks.require(value, name)
    }
}
