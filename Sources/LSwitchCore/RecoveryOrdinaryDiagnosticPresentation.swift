#if DEBUG
import Foundation

public struct RecoveryOrdinaryDiagnosticReport: Sendable {
    public let started: Bool
    public let armed: Bool
    public let capturedEvents: Int
    public let capturedUTF16Bytes: Int
    public let payloadCountReads: Int
    public let ledgerSubmissions: Int
    public let ordinaryClaim: Bool
    public let claimCount: Int
    public let wakePostAttempts: Int
    public let wakePostReturned: Bool
    public let completed: Bool
    public let adopted: Bool
    public let retainedEvents: Int
    public let retainedUTF16Bytes: Int
    public let payloadDeleted: Bool
    public let revealCount: Int
    public let delivery: OrdinaryDeliveryProgress?
    public let driver: RecipientTapDriverSnapshot
}

extension RecoveryOrdinaryDiagnostic {
    public var report: RecoveryOrdinaryDiagnosticReport {
        let counts = attachment?.counters
        let stored = coordinator.metadata
        return .init(started: started, armed: armed, capturedEvents: counts?.capturedEvents ?? 0,
                     capturedUTF16Bytes: counts?.capturedUTF16Bytes ?? 0,
                     payloadCountReads: counts?.payloadCountReads ?? 0,
                     ledgerSubmissions: ledger.submissionCount, ordinaryClaim: ledger.inputOwner == .ordinaryDelivery,
                     claimCount: claimCount, wakePostAttempts: wakePostAttempts, wakePostReturned: wakePostReturned,
                     completed: completed, adopted: adopted,
                     retainedEvents: stored?.eventCount ?? 0, retainedUTF16Bytes: stored?.utf16Bytes ?? 0,
                     payloadDeleted: stored?.payloadDeleted ?? false, revealCount: revealCount,
                     delivery: flush?.terminalProof?.progress, driver: driver.snapshot)
    }

    public var metadata: RecoveryWindowMetadata? {
        guard let stored = coordinator.metadata else { return nil }
        return .init(recordIdentifier: stored.identifier, applicationName: "Тестовый дочерний редактор",
                     counts: .init(events: stored.eventCount, utf16Bytes: stored.utf16Bytes),
                     reason: stored.ordinaryDelivery == nil ? .interceptionStopped : .ordinaryDeliveryUnconfirmed,
                     protection: driver.isProtectionAvailable ? .unverified : .unavailable,
                     ordinaryDelivery: stored.ordinaryDelivery)
    }

    public var quitActions: RecoveryQuitActions { coordinator.quitActions }

    public var actions: RecoveryWindowActions {
        .init(reveal: { [weak self] record in
            guard let self, self.coordinator.metadata?.identifier == record,
                  let intent = self.coordinator.requestReveal(), self.coordinator.reveal(intent) else { return nil }
            self.revealCount += 1
            return self.coordinator.revealedProjection
        }, requestDeletion: { [weak self] record in
            guard let self, self.coordinator.metadata?.identifier == record,
                  let intent = self.coordinator.requestDeletion() else { return nil }
            return .init(recordIdentifier: record,
                         confirm: { [weak self] in self?.coordinator.confirmDeletion(intent) == .deleted },
                         cancel: { [weak self] in _ = self?.coordinator.cancelDeletion(intent) })
        }, didHide: { [weak self] record in
            guard let self, self.coordinator.metadata?.identifier == record else { return }
            self.coordinator.hide()
        })
    }
}
#endif
