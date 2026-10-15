#if DEBUG
import Foundation
import LSwitchCore

/// Протокол содержит только счётчики собственного probe, без событий и текста редактора.
enum RecoveryRecipientProbeReporting {
    /// Наблюдённое разделение пары не доказывает prevention или безопасность отключённого tap.
    static func disabledPartition(blocked: [String], tail: [String], receiver: [String]) -> Bool {
        !tail.isEmpty && tail == receiver && (blocked + tail).sorted() == ["down", "up"]
    }

    static func fields(_ value: RecoveryRecipientProbeSnapshot) -> [String: Any] {
        [
            "phase": value.phase, "reservations": value.reservationCount,
            "prepared": value.preparedCount, "submitted": value.submittedCount,
            "admitted": value.admittedCount, "prevented": value.preventedCount,
            "unresolved": value.unresolvedCount, "downStatus": value.downStatus,
            "releaseStatus": value.releaseStatus, "handoverRequested": value.handoverRequested,
            "protectionAvailable": value.protectionAvailable, "lost": value.lost,
            "lossCount": value.lossCount, "pendingObservations": value.pendingObservationCount,
            "overflowCount": value.overflowCount, "callbackMismatchCount": value.callbackMismatchCount,
            "sourceRejectedCount": value.sourceRejectedCount, "markerRejectedCount": value.markerRejectedCount,
            "callbackAllowedCount": value.callbackAllowedCount, "callbackBlockedCount": value.callbackBlockedCount,
            "preflightRefusedCount": value.preflightRefusedCount,
            "registrationRefusedCount": value.registrationRefusedCount,
            "ledgerSubmissions": value.ledgerSubmissionCount, "ledgerReturned": value.ledgerReturnedCount,
            "ledgerAdmitted": value.ledgerAdmittedCount, "ledgerPrevented": value.ledgerPreventedCount,
            "ledgerUnknown": value.ledgerUnknownCount, "ledgerUnresolved": value.ledgerUnresolvedCount,
            "receiverCompleted": value.receiverCompleted, "replayAuthorized": value.replayAuthorized,
            "recoveryGateAccepted": value.recoveryGateAccepted
        ]
    }
}
#endif
