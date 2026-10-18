#if DEBUG
import Foundation

public struct TextEditRecoveryTiming: Equatable, Sendable {
    public let count: UInt64
    public let nanoseconds: UInt64

    init(_ timing: AXProfileTiming) { count = timing.count; nanoseconds = timing.nanoseconds }
}

/// Snapshot inclusive содержит вложенные guards; значения нельзя складывать как независимые интервалы.
/// Только вызовы внутри bound profile после prepare; внешние проверки Converter/settlement сюда не входят.
public struct TextEditRecoveryProfileReport: Equatable, Sendable {
    public let requestIsValid: TextEditRecoveryTiming
    public let source: TextEditRecoveryTiming
    public let protectedField: TextEditRecoveryTiming
    public let focus: TextEditRecoveryTiming
    public let context: TextEditRecoveryTiming
    public let snapshotInclusive: TextEditRecoveryTiming
    public let foreground: TextEditRecoveryTiming
    public let profileFault: String?
    public let logicalFailure: String?

    init(_ report: AXProfileDiagnosticReport, logicalFailure: EventProcessingInvalidation?) {
        requestIsValid = .init(report.requestIsValid)
        source = .init(report.source)
        protectedField = .init(report.protectedField)
        focus = .init(report.focus)
        context = .init(report.context)
        snapshotInclusive = .init(report.snapshotInclusive)
        foreground = .init(report.foreground)
        profileFault = report.profileFault.map(Self.label)
        self.logicalFailure = logicalFailure.map(Self.label)
    }

    private static func label(_ reason: ConversionSafetyProfileFault) -> String {
        switch reason {
        case .contextChanged: return "contextChanged"
        case .cancelled: return "cancelled"
        case .writeRejected: return "writeRejected"
        case .snapshotUnavailable: return "snapshotUnavailable"
        case .snapshotMismatch: return "snapshotMismatch"
        case .preparationFailed: return "preparationFailed"
        case .unknownSubmission: return "unknownSubmission"
        case .outstandingKeyDebt: return "outstandingKeyDebt"
        case .cleanupUnconfirmed: return "cleanupUnconfirmed"
        case .unconfirmedResult: return "unconfirmedResult"
        }
    }

    private static func label(_ reason: EventProcessingInvalidation) -> String {
        switch reason {
        case .inputBeforeCapture: return "inputBeforeCapture"
        case .expired: return "expired"
        case .eventLimit: return "eventLimit"
        case .payloadLimit: return "payloadLimit"
        case .invalidPayload: return "invalidPayload"
        case .focusChanged: return "focusChanged"
        case .stopped: return "stopped"
        case .permissionLost: return "permissionLost"
        case .captureRefused: return "captureRefused"
        }
    }
}

extension TextEditRecoveryRuntime {
    public var profileReport: TextEditRecoveryProfileReport? {
        guard let attempt, let profile = attempt.profile else { return lastProfileReport }
        return .init(profile.diagnosticReport, logicalFailure: logicalFailure(attempt))
    }

    func recordProfileReport(_ expected: TextEditRecoveryAttempt, finish: EventProcessingFinish? = nil) {
        guard attempt === expected || (attempt == nil && lastProfileInvocation == expected.invocation),
              let profile = expected.profile else { return }
        if case .reset(let reason) = finish { expected.logicalFailure = expected.logicalFailure ?? reason }
        expected.logicalFailure = logicalFailure(expected)
        lastProfileReport = .init(profile.diagnosticReport, logicalFailure: expected.logicalFailure)
        lastProfileInvocation = expected.invocation
    }

    private func logicalFailure(_ attempt: TextEditRecoveryAttempt) -> EventProcessingInvalidation? {
        if let failure = attempt.logicalFailure { return failure }
        guard let lease = attempt.lease else { return nil }
        return attempt.tap?.processingLeases.state.failure(for: lease)
    }
}
#endif
