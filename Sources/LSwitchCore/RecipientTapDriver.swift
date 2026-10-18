#if DEBUG
import Darwin
import Foundation

/// Системный DEBUG-кандидат. Не включён в production factory и не подтверждает receiver completion/replay.
public final class RecipientTapDriver: RecoveryIsolationProtecting, @unchecked Sendable {
    public let bridge: RecoveryRecipientProbeBridge
    private let state: RecipientTapDriverState
    private let worker: RecipientTapDriverWorker

    @MainActor
    public init?(bridge: RecoveryRecipientProbeBridge) {
        guard bridge.senderProcessID == getpid(),
              SystemProcessIdentity.isCurrent(bridge.capturedTargetIdentity),
              SystemProcessIdentity.isCurrent(bridge.capturedSenderIdentity) else { return nil }
        self.bridge = bridge
        let state = RecipientTapDriverState(bridge: bridge)
        self.state = state
        self.worker = RecipientTapDriverWorker(state: state, target: bridge.capturedTargetIdentity,
                                               sender: bridge.capturedSenderIdentity)
    }

    /// Создаёт worker до hold. Protection активирует Session отдельно, после готовности собственного scope.
    public func start() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [worker] in
                continuation.resume(returning: worker.startAndWait())
            }
        }
    }

    public var isProtectionAvailable: Bool { state.isProtectionAvailable }
    public var permitsMutation: Bool { state.permitsMutation }
    public var snapshot: RecipientTapDriverSnapshot { state.snapshot }

    /// Только создание ещё не опубликованного admission/hold; не право чтения или мутации редактора.
    var permitsCaptureReservation: Bool { state.canArmProtection || state.permitsMutation }

    @MainActor
    @discardableResult
    public func refreshProtection() -> Bool {
        _ = worker.refreshHealth()
        return state.isProtectionAvailable
    }

    /// До activation: не разрываем уже начатый AppKit mouse tracking loop.
    @MainActor
    public func canArmProtection() -> Bool {
        _ = worker.refreshHealth()
        return state.canArmProtection
    }

    @MainActor
    public func activateProtection() -> Bool {
        guard worker.refreshHealth(), let activation = bridge.prepareActivation() else { return false }
        return state.activateProtection(activation)
    }

    public func withProtection(_ body: () -> Void) { state.withProtection(body) }

    /// Одноразовый endpoint готовится после capture reservation, до selection. Payload остаётся у Session.
    @MainActor
    func bindFixtureCapture(router: RecoveryCaptureRouter, filter: RecoveryFixtureCaptureFilter) -> Bool {
        guard !Task.isCancelled, state.permitsMutation,
              filter.senderProcessID == bridge.senderProcessID,
              filter.downMarker > 0, filter.releaseMarker > 0, filter.downMarker != filter.releaseMarker,
              filter.downMarker != SyntheticEventMarker.magic, filter.releaseMarker != SyntheticEventMarker.magic,
              !bridge.owns(senderPID: Int64(filter.senderProcessID), marker: filter.downMarker),
              !bridge.owns(senderPID: Int64(filter.senderProcessID), marker: filter.releaseMarker) else { return false }
        return state.captureEndpoint.bind(router: router, filter: filter, scope: bridge.capturedScope)
    }

    /// Scope проверяется до публикации. Этот endpoint обслуживает только выбранный per-PID worker.
    @MainActor
    func bindRecipientInput(router: RecoveryCaptureRouter) -> Bool {
        guard !Task.isCancelled, state.permitsMutation else { return false }
        return state.captureEndpoint.bindRecipientInput(router: router, scope: bridge.capturedScope)
    }

    /// Внешний app-owner уже зарегистрировал Session. Возврат true предшествует первой мутации редактора.
    @MainActor
    func armRecipientCapture(
        _ capture: RecipientOrdinaryCapture, processingArm: PreparedEventProcessingArm? = nil
    ) async -> Bool {
        guard !Task.isCancelled, capture.scope.binding.scope == bridge.capturedScope,
              processingArm?.matches(capture) != false,
              worker.refreshHealth(), let activation = bridge.prepareActivation() else { return false }
        let request = RecipientCaptureArming(state: state, capture: capture, activation: activation,
                                            processingArm: processingArm)
        let result = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                request.register(continuation)
                if !worker.enqueue({ request.run() }) { request.cancel() }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(250)) {
                    request.expireIfPending()
                }
            }
        }, onCancel: { request.cancel() })
        guard !Task.isCancelled else { request.cancel(); return false }
        return result && state.permitsMutation && (processingArm?.isCurrent ?? true)
    }

    /// Подготовка не claim-ит очередь и не отправляет marker. Diagnostic значение выделяется самим fixture заранее.
    @MainActor
    func prepareOrdinaryFlush(
        capture: RecipientOrdinaryCapture, deadline: UInt64, diagnosticMarker: Int64? = nil
    ) -> RecipientOrdinaryFlush? {
        let now = DispatchTime.now().uptimeNanoseconds
        guard !Task.isCancelled, deadline > now, deadline - now <= 400_000_000,
              capture.scope.binding.scope == bridge.capturedScope, state.permitsMutation,
              let marker = RecipientOrdinaryMarker(sourcePID: bridge.senderProcessID,
                                                   diagnosticValue: diagnosticMarker) else { return nil }
        let flush = RecipientOrdinaryFlush(capture: capture, state: state, marker: marker,
                                          timing: .init(deadline: deadline))
        return state.installOrdinaryFlush(flush) ? flush : nil
    }

    public func closeGeneration() { bridge.closeGeneration() }

    /// EOF не возобновляет прежний scope и не снимает target quarantine автоматически.
    public func markPeerEOF() { state.markLost(.peerEOF) }

    @MainActor
    @discardableResult
    public func drainObservations() -> RecoveryRecipientProbeSnapshot {
        _ = refreshProtection()
        return bridge.drainObservations()
    }

    /// Отдельный shutdown, не OFF-контракт production. Ничего не отправляет и не освобождает held input.
    public func stop() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [worker] in
                continuation.resume(returning: worker.stopAndWait())
            }
        }
    }

    deinit { worker.requestStop(.stopped) }
}
#endif
