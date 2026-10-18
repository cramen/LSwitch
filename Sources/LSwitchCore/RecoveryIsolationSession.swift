#if DEBUG
import Darwin
import Dispatch
import Foundation

/// Один app-owned ledger и настоящий capture→handover. Нет populate и production receiver/replay permit.
@MainActor
public final class RecoveryIsolationSession {
    private static let fixtureMarkers = NativeDispatchMarkers()
    public let bridge: RecoveryRecipientProbeBridge
    let ledger: ConversionSafetyLedger
    let coordinator: RecoveryCoordinator
    private let sender: RecoveryProcessIdentity
    private let target: RecoveryProcessIdentity
    private let filter: RecoveryFixtureCaptureFilter
    private let identityCheck: @MainActor @Sendable (RecoveryProcessIdentity) -> Bool
    private let clock: @Sendable () -> UInt64
    private let protectionSlot: RecoveryIsolationProtectionSlot
    private var protection: (any RecoveryIsolationProtecting)?
    private var operation: RecoveryOperation?
    private var attachment: RecoveryCaptureAttachment?
    private var router: RecoveryCaptureRouter?
    private var selectionToken: ConversionSafetySubmissionToken?
    private var selectionUnknown = false
    private var detached = false
    private var adopted = false
    private var storageOnlyAdopted = false
    private var retirementPending = false
    private var reveals = 0
    private var preparationStarted = false

    init?(
        sender: RecoveryProcessIdentity, target: RecoveryProcessIdentity, filter: RecoveryFixtureCaptureFilter,
        identityCheck: @escaping @MainActor @Sendable (RecoveryProcessIdentity) -> Bool,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        let ledger = ConversionSafetyLedger(generation: 1)
        let scope = RecoveryOperationTarget(operation: ledger.operation, target: target)
        guard sender.processID != target.processID, filter.senderProcessID == sender.processID,
              filter.downMarker > 0, filter.releaseMarker > 0, filter.downMarker != filter.releaseMarker,
              filter.downMarker != SyntheticEventMarker.magic, filter.releaseMarker != SyntheticEventMarker.magic,
              let gate = RecipientGateState(scope: scope),
              let bridge = RecoveryRecipientProbeBridge(sender: sender, target: target, ledger: ledger, gate: gate,
                                                        identityCheck: identityCheck) else { return nil }
        let slot = RecoveryIsolationProtectionSlot()
        self.sender = sender
        self.target = target
        self.filter = filter
        self.identityCheck = identityCheck
        self.clock = clock
        self.ledger = ledger
        self.bridge = bridge
        protectionSlot = slot
        coordinator = RecoveryCoordinator(gateFactory: .init(prepare: { scope in
            guard slot.permitsMutation else { return nil }
            return RecoveryGateCapability(scope: scope, isCurrent: { slot.permitsMutation })
        }))
    }

    public static func allocateFixtureMarkers() -> RecoveryIsolationFixtureMarkers? {
        guard let values = fixtureMarkers?.reserve(4), values.count == 4 else { return nil }
        return .init(prefixDown: values[0], prefixRelease: values[1],
                     challengeDown: values[2], challengeRelease: values[3])
    }

    public static func make(
        targetPID: Int32, prefixDownMarker: Int64, prefixReleaseMarker: Int64
    ) -> RecoveryIsolationSession? {
        guard let sender = SystemProcessIdentity.read(processID: getpid()),
              let target = SystemProcessIdentity.read(processID: targetPID) else { return nil }
        return .init(sender: sender, target: target,
                     filter: .init(senderProcessID: sender.processID,
                                   downMarker: prefixDownMarker, releaseMarker: prefixReleaseMarker),
                     identityCheck: { SystemProcessIdentity.isCurrent($0) })
    }

    public var targetIsCurrent: Bool { identityCheck(sender) && identityCheck(target) }

    /// Альтернативный upfront маршрут. Общий session tap для этой операции не создаётся.
    public func prepareRecipientCapture(on driver: RecipientTapDriver) -> Bool {
        prepareRecipientCapture(protection: driver, bind: { router, filter in
            driver.bindFixtureCapture(router: router, filter: filter)
        })
    }

    func prepareRecipientCapture(
        protection: any RecoveryIsolationProtecting,
        bind: (RecoveryCaptureRouter, RecoveryFixtureCaptureFilter) -> Bool
    ) -> Bool {
        let router = RecoveryCaptureRouter(bypassRawProcessing: true)
        guard prepareCapture(router: router, protection: protection) else { return false }
        guard bind(router, filter), !Task.isCancelled, targetIsCurrent, let attachment else {
            markPeerUnavailable()
            return false
        }
        attachment.expire()
        guard attachment.port.permitsMutation(for: attachment.port.scope) else {
            markPeerUnavailable()
            return false
        }
        attachment.scheduleExpiry()
        return true
    }

    public func prepareCapture(on tap: EventTapCore, protection: any RecoveryIsolationProtecting) -> Bool {
        guard tap.state == .running, !tap.hasLegacyInputHold,
              prepareCapture(router: tap.recoveryCaptureRouter, protection: protection), let attachment else {
            return false
        }
        tap.scheduleRecoveryCaptureExpiry(attachment)
        return true
    }

    /// Чистая точка подключения используется компонентными тестами без создания системного tap.
    func prepareCapture(
        router: RecoveryCaptureRouter, protection: any RecoveryIsolationProtecting,
        observePhase: @escaping @Sendable (RecoveryCapturePhase) -> Void = { _ in }
    ) -> Bool {
        guard !Task.isCancelled, !preparationStarted, router.bypassRawProcessing,
              protection.bridge === bridge else { return false }
        preparationStarted = true
        guard targetIsCurrent, protection.activateProtection(), protection.refreshProtection(),
              protectionSlot.bind(protection), protectionSlot.permitsMutation else {
            markPeerUnavailable()
            return false
        }
        self.protection = protection
        let slot = protectionSlot
        guard let admission = coordinator.reserve(operation: ledger.operation, target: target),
              let operation = RecoveryOperation.prepare(
                ledger: ledger, admission: admission, tapIdentifier: router.identifier,
                at: clock(),
                handoverFactory: .init(prepare: { scope, identifier in
                    PreparedRecoveryHandover(operationScope: scope, tapIdentifier: identifier,
                                            protecting: { _, body in slot.withProtection(body) })
                })
        ) else { markPeerUnavailable(); return false }
        self.operation = operation
        let attachment = RecoveryCaptureAttachment(port: operation.capturePort, filter: filter,
                                                   ownMarker: { [bridge] in bridge.owns(senderPID: $0, marker: $1) },
                                                   clock: clock, observePhase: observePhase)
        self.attachment = attachment
        guard !Task.isCancelled, targetIsCurrent, router.attach(attachment) else {
            markPeerUnavailable()
            return false
        }
        self.router = router
        return true
    }

    /// Проверяет живой admission без регистрации команды или чтения payload.
    func captureIsCurrentForDiagnostics() -> Bool {
        guard !Task.isCancelled, !detached, router != nil, targetIsCurrent,
              protection?.refreshProtection() == true, let operation else { return false }
        attachment?.expire()
        return operation.capturePort.permitsMutation(for: operation.capturePort.scope)
    }

    /// Это submission отдельной fixture IPC-команды, не подтверждение или приёмка AX setter.
    public func beginFixtureSelectionCommand() -> Bool {
        guard !Task.isCancelled, selectionToken == nil, targetIsCurrent,
              protection?.refreshProtection() == true, let operation else { return false }
        attachment?.expire()
        guard !Task.isCancelled, operation.capturePort.permitsMutation(for: operation.capturePort.scope),
              let token = ledger.willSubmit(.selection, operation: ledger.operation) else { return false }
        selectionToken = token
        return true
    }

    public func markFixtureSelectionUnknown(commandReturned: Bool) {
        guard let selectionToken, !selectionUnknown else { return }
        ledger.observe(.adapterReturned(commandReturned), for: selectionToken)
        selectionUnknown = ledger.observe(.unknown, for: selectionToken)
    }

    @discardableResult
    public func finishForRecovery(on tap: EventTapCore? = nil) -> Bool {
        guard let operation, let attachment, let router,
              tap == nil || tap?.recoveryCaptureRouter === router else { return false }
        if !targetIsCurrent || protection?.refreshProtection() != true { markPeerUnavailable() }
        bridge.closeGeneration()
        _ = bridge.drainObservations()
        if selectionToken != nil, !selectionUnknown { markFixtureSelectionUnknown(commandReturned: false) }
        guard case .detached = operation.closeCapture() else { return adopted }
        detached = router.detach(attachment) || detached
        if ledger.decision == nil {
            _ = ledger.finishUsingRecordedCleanup(
                operation: ledger.operation, text: .unknown, ordinaryRouteValid: false
            )
        }
        guard case .adopted = operation.adopt(in: coordinator, reason: .cleanupUnconfirmed) else { return false }
        adopted = true
        return true
    }

    public func markPeerUnavailable() {
        protectionSlot.invalidate()
        bridge.markLost()
        attachment?.invalidate(.gateUnavailable)
        coordinator.permissionsLost()
    }

    /// Retryable storage-only переход. Потеря защиты не отменяет pending отправки и не разрешает replay.
    @discardableResult
    public func finishForStorageRecovery() -> Bool {
        if adopted { return storageOnlyAdopted }
        guard let operation, let attachment, let router else { return false }
        retirementPending = true
        protectionSlot.invalidate()
        bridge.markLost()
        guard operation.closeCaptureForStorage(router: router, attachment: attachment) else { return false }
        detached = true
        retirementPending = false
        coordinator.permissionsLost()
        _ = bridge.drainObservations()
        if selectionToken != nil, !selectionUnknown { markFixtureSelectionUnknown(commandReturned: false) }
        if ledger.decision == nil {
            _ = ledger.finishUsingRecordedCleanup(
                operation: ledger.operation, text: .unknown, ordinaryRouteValid: false
            )
        }
        guard case .adopted = operation.adopt(in: coordinator, reason: .cleanupUnconfirmed) else { return false }
        adopted = true
        storageOnlyAdopted = true
        return true
    }

    public func show() { coordinator.show() }

    public var quitActions: RecoveryQuitActions { coordinator.quitActions }

    public var metadata: RecoveryWindowMetadata? {
        guard let stored = coordinator.metadata else { return nil }
        return .init(recordIdentifier: stored.identifier, applicationName: "Тестовый дочерний редактор",
                     counts: .init(events: stored.eventCount, utf16Bytes: stored.utf16Bytes),
                     reason: .cleanupUnconfirmed,
                     protection: protectionSlot.isProtectionAvailable ? .unverified : .unavailable)
    }

    public var actions: RecoveryWindowActions {
        .init(reveal: { [weak self] record in
            guard let self, self.coordinator.metadata?.identifier == record,
                  let intent = self.coordinator.requestReveal(), self.coordinator.reveal(intent) else { return nil }
            self.reveals += 1
            return self.coordinator.revealedProjection
        }, requestDeletion: { [weak self] record in
            guard let self, self.coordinator.metadata?.identifier == record,
                  let intent = self.coordinator.requestDeletion() else { return nil }
            return .init(recordIdentifier: record, confirm: { [weak self] in
                self?.coordinator.confirmDeletion(intent) == .deleted
            }, cancel: { [weak self] in _ = self?.coordinator.cancelDeletion(intent) })
        }, didHide: { [weak self] record in
            guard let self, self.coordinator.metadata?.identifier == record else { return }
            self.coordinator.hide()
        })
    }

    public var report: RecoveryIsolationReport {
        let counts = attachment?.counters
        let stored = coordinator.metadata
        return .init(
            senderProcessID: sender.processID, targetProcessID: target.processID,
            capturedEvents: counts?.capturedEvents ?? 0, capturedUTF16Bytes: counts?.capturedUTF16Bytes ?? 0,
            rejectedFixtureEvents: counts?.rejectedEvents ?? 0, payloadCountReads: counts?.payloadCountReads ?? 0,
            captureAttached: router != nil && !detached, captureDetached: detached,
            selectionCommandRegistered: selectionToken != nil, selectionUnknown: selectionUnknown, adopted: adopted,
            retainedBeforeAdoption: operation != nil && !adopted,
            preAdoptLossUnresolved: operation != nil && !adopted && !protectionSlot.isProtectionAvailable,
            storageOnlyAdopted: storageOnlyAdopted, retirementPending: retirementPending,
            eventsRemaining: stored?.eventCount ?? counts?.capturedEvents ?? 0,
            utf16BytesRemaining: stored?.utf16Bytes ?? counts?.capturedUTF16Bytes ?? 0,
            ledgerSubmissionCount: ledger.submissionCount, ledgerHasUnknown: ledger.hasUnknownSubmissions,
            recoveryRequired: ledger.decision?.input == .recoveryRequired,
            inputClaimedForRecovery: ledger.inputOwner == .recovery,
            payloadDeleted: stored?.payloadDeleted ?? false, revealCount: reveals
        )
    }
}
#endif
