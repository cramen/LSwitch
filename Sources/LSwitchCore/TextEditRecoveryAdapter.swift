#if DEBUG
import Foundation

/// Один adapter удерживает native owner/proof до Coordinator; Session видит отдельный completion handle.
@MainActor
final class TextEditRecoveryAdapter: ConversionRecoveryAdapter {
    let resources: TextEditRecoveryAdapterResources
    private let contextIsCurrent: Converter.ContextCheck
    private let currentSafety: () -> Bool
    private let changed: () -> Void
    private var registered = false
    private var armed = false
    private var invalidated = false
    private var recoveryClaim: ConversionSafetyInputClaim?
    private var flush: RecipientOrdinaryFlush?
    private var sessionTransport: ConversionOrdinaryTransport?
    private var nativeWaiter: Task<Bool, Never>?
    private var retirement: Task<Bool, Never>?
    private var stopping: Task<Bool, Never>?
    private var acceptanceStarted = false
    private var stopAfterRetain = false
    private(set) var ordinaryCompleted = false
    private(set) var adopted = false
    private(set) var driverStopped = false
    private(set) var correction: ConversionRecoveryLayoutTransition?
    private(set) var reason = RecoveryReason.admissionStopped

    init(
        resources: TextEditRecoveryAdapterResources, contextIsCurrent: @escaping Converter.ContextCheck,
        currentSafety: @escaping () -> Bool, changed: @escaping () -> Void
    ) {
        self.resources = resources
        self.contextIsCurrent = contextIsCurrent
        self.currentSafety = currentSafety
        self.changed = changed
    }

    var isCaptureValid: Bool {
        guard registered, armed, !invalidated, !Task.isCancelled else { return false }
        guard currentSafety(), contextIsCurrent(), resources.logical.isCurrent(), resources.capture.isCurrent else {
            return false
        }
        return registered && armed && !invalidated
    }

    var isOrdinaryRouteCurrent: Bool { isCaptureValid }
    var hasPending: Bool { !ordinaryCompleted }
    var hasUnsettled: Bool { retirement != nil || stopping != nil || (!adopted && !ordinaryCompleted) }

    func activateCapture() -> Bool {
        guard !registered, !invalidated, resources.logical.prepared.matches(resources.capture) else { return false }
        registered = true
        return true
    }

    func arm() async -> Bool {
        guard registered, !invalidated else { return false }
        armed = await resources.driver.armRecipientCapture(
            resources.capture, processingArm: resources.logical.prepared)
        return isCaptureValid
    }

    func beginMutation() -> Bool { isCaptureValid }
    func drainPendingInput() async { await resources.logical.drain() }

    func prepareOrdinary() -> Bool {
        guard flush == nil, isCaptureValid,
              let prepared = resources.driver.prepareOrdinaryFlush(
                capture: resources.capture, deadline: resources.logical.prepared.deadline, diagnosticMarker: nil
              ) else { return false }
        flush = prepared
        return isCaptureValid
    }

    func commitOrdinary(
        correction: ConversionRecoveryLayoutTransition?, claimOwnership: () -> ConversionSafetyInputClaim?
    ) -> ConversionOrdinaryAcceptance {
        guard !acceptanceStarted, isOrdinaryRouteCurrent, let flush else { return .refused }
        acceptanceStarted = true
        self.correction = correction
        let acceptance = resources.driver.acceptOrdinary(flush, correction: correction, claimOwnership: claimOwnership)
        guard case .accepted = acceptance else {
            if resources.ledger.inputOwner == .transaction { acceptanceStarted = false }
            return .refused
        }
        let completion = ConversionOrdinaryTransport(onRetentionRequested: { [weak flush] in
            flush?.requestRetention()
        })
        sessionTransport = completion
        nativeWaiter = Task { @MainActor [weak self, flush] in
            let result = await flush.transport.waitForTerminal()
            guard let self else { return false }
            let consumed = self.consumeTerminal(flush, result: result)
            if consumed { self.changed() }
            return consumed
        }
        return .accepted(completion)
    }

    private func consumeTerminal(_ flush: RecipientOrdinaryFlush, result: ConversionOrdinaryTransportResult?) -> Bool {
        guard let proof = flush.terminalProof else { return false }
        if result == .locallyDispatched {
            guard resources.coordinator.completeOrdinary(proof: proof) else { return false }
            ordinaryCompleted = true
            sessionTransport?.complete(.locallyDispatched)
            return true
        }
        guard result == .retainedFailure,
              case .adopted = resources.coordinator.adoptRetainedOrdinary(proof: proof) else { return false }
        adopted = true
        reason = .ordinaryDeliveryUnconfirmed
        sessionTransport?.complete(.retainedFailure)
        return true
    }

    func retainForRecovery(claim: ConversionSafetyInputClaim?) {
        invalidated = true
        resources.logical.prepared.invalidate(.stopped)
        resources.capture.invalidate()
        if let claim, claim.owner == .recovery, claim.operation == resources.ledger.operation, recoveryClaim == nil {
            recoveryClaim = claim
        }
        flush?.requestRetention()
        startRetirement()
    }

    /// Только для отказа factory до регистрации Session. Уже выданный ordinary claim не заменяется.
    func retainBeforeSession() {
        if resources.ledger.decision == nil {
            _ = resources.ledger.finish(operation: resources.ledger.operation, text: .unchangedByOperation,
                                        cleanup: .noOwnedMutation, ordinaryRouteValid: false)
        }
        if resources.ledger.inputOwner == .transaction, resources.ledger.currentInputDisposition == .recoveryRequired {
            recoveryClaim = resources.ledger.claimInput(operation: resources.ledger.operation)
        }
        retainForRecovery(claim: recoveryClaim)
    }

    func interrupt(_ interruption: TextEditRecoveryInterruption) {
        invalidated = true
        stopAfterRetain = stopAfterRetain || interruption.stopsDriver
        resources.logical.prepared.invalidate(interruption.logicalReason)
        resources.capture.invalidate()
        resources.driver.bridge.closeGeneration()
        switch interruption {
        case .off: resources.coordinator.setEnabled(false); reason = .interceptionStopped
        case .permissionLost, .tapLost: resources.coordinator.permissionsLost(); reason = .gateLost
        case .focusChanged, .shutdown: reason = .interceptionStopped
        }
        flush?.requestRetention()
    }

    private func startRetirement() {
        guard retirement == nil else { return }
        retirement = Task { @MainActor [weak self] in
            guard let self else { return false }
            let result = await self.retire()
            self.retirement = nil
            self.changed()
            return result
        }
    }

    func awaitRecovery() async -> Bool {
        if ordinaryCompleted { return stopAfterRetain ? await stopDriver() : true }
        startRetirement()
        return await retirement?.value ?? adopted
    }

    private func retire() async -> Bool {
        if acceptanceStarted || resources.ledger.inputOwner == .ordinaryDelivery {
            flush?.requestRetention()
            guard let nativeWaiter else { return false }
            _ = await nativeWaiter.value
            guard ordinaryCompleted || adopted else { return false }
        } else if !adopted {
            guard let recoveryClaim else { return false }
            resources.driver.bridge.closeGeneration()
            resources.capture.invalidate()
            for _ in 0..<40 {
                if resources.operation.closeCaptureForStorage(
                    router: resources.capture.router, attachment: resources.capture.attachment
                ) { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            guard case .adopted = resources.operation.capturePort.adopt(
                in: resources.coordinator, claim: recoveryClaim, reason: reason
            ) else { return false }
            adopted = true
        }
        if stopAfterRetain { return await stopDriver() }
        return adopted || ordinaryCompleted
    }

    func stopDriver() async -> Bool {
        if driverStopped { return true }
        if let stopping { return await stopping.value }
        let driver = resources.driver
        let task = Task { await driver.stop() }
        stopping = task
        driverStopped = await task.value
        stopping = nil
        return driverStopped
    }
}
#endif
