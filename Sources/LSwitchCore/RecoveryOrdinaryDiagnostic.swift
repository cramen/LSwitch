#if DEBUG
import CoreGraphics
import Darwin
import Foundation

public enum RecoveryOrdinaryDiagnosticCompletion: String, Sendable {
    case completed, retained, refused, pending
}

/// Внутренняя граница для memory-only проверки lifecycle без создания native taps.
struct RecoveryOrdinaryDiagnosticResources {
    let ledger: ConversionSafetyLedger
    let coordinator: RecoveryCoordinator
    let driver: RecipientTapDriver
    let sender: RecoveryProcessIdentity
    let target: RecoveryProcessIdentity
    let router: RecoveryCaptureRouter
}

/// Внешний App держит этот объект до завершения driver и явного решения о pending RAM.
/// Это fixture-only facade: production factory и глобальный EventTapCore не подключаются.
@MainActor
public final class RecoveryOrdinaryDiagnostic {
    let ledger: ConversionSafetyLedger
    let coordinator: RecoveryCoordinator
    let driver: RecipientTapDriver
    let sender: RecoveryProcessIdentity
    let target: RecoveryProcessIdentity
    let wakeMarker: Int64
    let router: RecoveryCaptureRouter
    var operation: RecoveryOperation?
    var attachment: RecoveryCaptureAttachment?
    var capture: RecipientOrdinaryCapture?
    var flush: RecipientOrdinaryFlush?
    var completionTask: Task<RecoveryOrdinaryDiagnosticCompletion, Never>?
    var ordinaryAcceptanceStarted = false
    var started = false
    var armStarted = false
    var armed = false
    var completed = false
    var adopted = false
    var claimCount = 0
    var wakePostAttempts = 0
    var wakePostReturned = false
    var revealCount = 0

    init(resources: RecoveryOrdinaryDiagnosticResources, wakeMarker: Int64) {
        ledger = resources.ledger
        coordinator = resources.coordinator
        driver = resources.driver
        sender = resources.sender
        target = resources.target
        router = resources.router
        self.wakeMarker = wakeMarker
    }

    private convenience init?(sender: RecoveryProcessIdentity, target: RecoveryProcessIdentity, wakeMarker: Int64) {
        let ledger = ConversionSafetyLedger(generation: 1)
        let scope = RecoveryOperationTarget(operation: ledger.operation, target: target)
        guard sender.processID != target.processID, wakeMarker > 0,
              let gate = RecipientGateState(scope: scope),
              let bridge = RecoveryRecipientProbeBridge(sender: sender, target: target, ledger: ledger, gate: gate),
              let driver = RecipientTapDriver(bridge: bridge) else { return nil }
        let coordinator = RecoveryCoordinator(gateFactory: .init(prepare: { scope in
            guard scope == bridge.capturedScope, driver.permitsCaptureReservation else { return nil }
            return .init(scope: scope, isCurrent: { driver.permitsCaptureReservation })
        }))
        let router = RecoveryCaptureRouter(bypassRawProcessing: true, acceptsRecipientInput: true)
        self.init(resources: .init(ledger: ledger, coordinator: coordinator, driver: driver,
                                   sender: sender, target: target, router: router),
                  wakeMarker: wakeMarker)
    }

    public static func make(targetPID: Int32, wakeMarker: Int64) -> RecoveryOrdinaryDiagnostic? {
        guard let sender = SystemProcessIdentity.read(processID: getpid()),
              let target = SystemProcessIdentity.read(processID: targetPID) else { return nil }
        return .init(sender: sender, target: target, wakeMarker: wakeMarker)
    }

    public var targetIsCurrent: Bool {
        SystemProcessIdentity.isCurrent(sender) && SystemProcessIdentity.isCurrent(target)
    }

    public func start() async -> Bool {
        guard !started, !Task.isCancelled, targetIsCurrent else { return false }
        started = await driver.start()
        return started && !Task.isCancelled && targetIsCurrent
    }

    public func arm() async -> Bool {
        guard started, !armStarted, !Task.isCancelled, targetIsCurrent, driver.canArmProtection() else { return false }
        armStarted = true
        guard let admission = coordinator.reserve(operation: ledger.operation, target: target) else { return false }
        let driver = self.driver
        guard let operation = RecoveryOperation.prepare(
            ledger: ledger, admission: admission, tapIdentifier: router.identifier,
            at: DispatchTime.now().uptimeNanoseconds,
            handoverFactory: .init(prepare: { scope, identifier in
                .init(operationScope: scope, tapIdentifier: identifier,
                      protecting: { _, body in driver.withProtection(body) })
            })
        ) else { _ = coordinator.abandonBeforeHold(admission); return false }
        self.operation = operation
        let bridge = driver.bridge
        let attachment = RecoveryCaptureAttachment(
            port: operation.capturePort, policy: .recipientInput,
            ownMarker: { bridge.owns(senderPID: $0, marker: $1) }
        )
        self.attachment = attachment
        guard router.attach(attachment), let capture = RecipientOrdinaryCapture(
            router: router, attachment: attachment, scope: bridge.capturedScope
        ) else { return false }
        self.capture = capture
        attachment.scheduleExpiry()
        armed = await driver.armRecipientCapture(capture)
        return armed && !Task.isCancelled && targetIsCurrent && capture.isCurrent
    }

    public var captureIsCurrent: Bool { targetIsCurrent && capture?.isCurrent == true }

    /// Callback проверяет только focus/flags; собственный CGEvent и private originals наружу не выходят.
    public func commit(
        refuseWake: Bool, permitsWake: @escaping @MainActor () -> Bool
    ) async -> RecoveryOrdinaryDiagnosticCompletion {
        guard completionTask == nil, ledger.decision == nil, ledger.submissionCount == 0,
              captureIsCurrent, let capture, let operation,
              attachment?.counters.capturedEvents == 2, attachment?.counters.capturedUTF16Bytes == 16,
              let flush = driver.prepareOrdinaryFlush(
                capture: capture, deadline: operation.capturePort.holdDeadline, diagnosticMarker: wakeMarker
              ) else { return .refused }
        self.flush = flush
        guard ledger.finish(operation: ledger.operation, text: .unchangedByOperation,
                            cleanup: .noOwnedMutation, ordinaryRouteValid: true)?.input == .replayAuthorized else {
            return .refused
        }
        ordinaryAcceptanceStarted = true
        let acceptance = flush.accept(correction: nil, claimOwnership: { [self] in
            guard let claim = ledger.claimInput(operation: ledger.operation) else { return nil }
            claimCount += 1
            return claim
        }, postWake: { [self] event in
            guard !refuseWake, permitsWake(), !Task.isCancelled, targetIsCurrent else { return false }
            wakePostAttempts += 1
            event.postToPid(target.processID)
            wakePostReturned = true
            return true
        })
        guard case .accepted(let transport) = acceptance else {
            if ledger.inputOwner == .transaction { ordinaryAcceptanceStarted = false }
            return .refused
        }
        let task = Task { @MainActor [weak self, flush] in
            let result = await transport.waitForTerminal()
            return self?.consumeTerminal(flush, result: result) ?? .pending
        }
        completionTask = task
        return await task.value
    }

    private func consumeTerminal(
        _ flush: RecipientOrdinaryFlush, result: ConversionOrdinaryTransportResult?
    ) -> RecoveryOrdinaryDiagnosticCompletion {
        guard let proof = flush.terminalProof else { return .pending }
        if result == .locallyDispatched, coordinator.completeOrdinary(proof: proof) {
            completed = true
            return .completed
        }
        guard result == .retainedFailure,
              case .adopted = coordinator.adoptRetainedOrdinary(proof: proof) else { return .pending }
        adopted = true
        return .retained
    }

    /// Retry лишь RAM quiescence/adopt. Нет post, второго ordinary claim или автоматического удаления.
    public func retainForRecovery() async -> Bool {
        if adopted { return true }
        if completed { return false }
        if ordinaryAcceptanceStarted || ledger.inputOwner == .ordinaryDelivery {
            return await retainOrdinaryDelivery()
        }
        guard let operation, let attachment else { return false }
        driver.bridge.markLost()
        coordinator.permissionsLost()
        attachment.invalidate(.interceptionStopped)
        for _ in 0..<40 {
            if operation.closeCaptureForStorage(router: router, attachment: attachment) { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if ledger.decision == nil {
            _ = ledger.finish(operation: ledger.operation, text: .unchangedByOperation,
                              cleanup: .noOwnedMutation, ordinaryRouteValid: false)
        } else if ledger.inputOwner == .transaction {
            _ = ledger.recordOrdinaryDeliveryRefusal(operation: ledger.operation)
        }
        guard case .adopted = operation.adopt(in: coordinator, reason: .interceptionStopped) else { return false }
        adopted = true
        return true
    }

    private func retainOrdinaryDelivery() async -> Bool {
        guard let flush else { return false }
        flush.requestRetention()
        // Внешний permitsWake может войти повторно до публикации completionTask.
        // Ordinary owner уже существует: storage fallback не имеет права изъять его proof.
        guard let completionTask else { return false }
        _ = await completionTask.value
        if adopted { return true }
        return consumeTerminal(flush, result: .retainedFailure) == .retained
    }

    public var hasPendingInput: Bool { operation != nil && !completed }
    public func markPeerLost() { driver.markPeerEOF(); coordinator.permissionsLost(); flush?.requestRetention() }
    public func stopDriver() async -> Bool { await driver.stop() }
    public func show() { coordinator.show() }
}
#endif
