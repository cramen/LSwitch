#if DEBUG
import Foundation

extension TextEditRecoveryRuntime {
    public var metadata: RecoveryWindowMetadata? {
        guard let adapter = attempt?.adapter, let stored = adapter.resources.coordinator.metadata else { return nil }
        let reason: RecoveryWindowReason
        switch stored.reason {
        case .cleanupUnconfirmed: reason = .cleanupUnconfirmed
        case .admissionStopped: reason = .admissionStopped
        case .gateLost: reason = .gateLost
        case .interceptionStopped: reason = .interceptionStopped
        case .ordinaryDeliveryUnconfirmed: reason = .ordinaryDeliveryUnconfirmed
        }
        let protection: RecoveryWindowProtection
        switch stored.protection {
        case .interceptionOff: protection = .off
        case .unavailable: protection = .unavailable
        case .unverified: protection = adapter.resources.driver.isProtectionAvailable ? .unverified : .unavailable
        }
        return .init(recordIdentifier: stored.identifier, applicationName: "TextEdit",
                     counts: .init(events: stored.eventCount, utf16Bytes: stored.utf16Bytes),
                     reason: reason, protection: protection, ordinaryDelivery: stored.ordinaryDelivery)
    }

    public func show() { attempt?.adapter?.resources.coordinator.show() }

    public var actions: RecoveryWindowActions {
        guard let coordinator = attempt?.adapter?.resources.coordinator else {
            return .init(reveal: { _ in nil }, requestDeletion: { _ in nil }, didHide: { _ in })
        }
        return .init(reveal: { [weak coordinator] record in
            guard let coordinator, coordinator.metadata?.identifier == record,
                  let intent = coordinator.requestReveal(), coordinator.reveal(intent) else { return nil }
            return coordinator.revealedProjection
        }, requestDeletion: { [weak coordinator] record in
            guard let coordinator, coordinator.metadata?.identifier == record,
                  let intent = coordinator.requestDeletion() else { return nil }
            return .init(recordIdentifier: record,
                         confirm: { [weak coordinator] in coordinator?.confirmDeletion(intent) == .deleted },
                         cancel: { [weak coordinator] in _ = coordinator?.cancelDeletion(intent) })
        }, didHide: { [weak coordinator] record in
            guard coordinator?.metadata?.identifier == record else { return }
            coordinator?.hide()
        })
    }

    public var quitActions: RecoveryQuitActions {
        .init { [weak self] in
            guard let self, !self.status.hasUnsettled else { return .handoverRequired }
            guard let coordinator = self.attempt?.adapter?.resources.coordinator else {
                guard !self.owner.isOccupied else { return .handoverRequired }
                self.quitAuthorized = true
                return .allowed
            }
            switch coordinator.quitActions.request() {
            case .handoverRequired: return .handoverRequired
            case .allowed:
                self.quitAuthorized = true
                return .allowed
            case .confirmationRequired(let confirmation):
                return .confirmationRequired(.init(recordIdentifier: confirmation.recordIdentifier,
                    confirm: { [weak self] in
                        guard let self, self.attempt?.adapter?.resources.coordinator === coordinator,
                              !self.status.hasUnsettled, confirmation.confirm() else { return false }
                        self.quitAuthorized = true
                        return true
                    }, cancel: { confirmation.cancel() }))
            }
        }
    }
}
#endif
