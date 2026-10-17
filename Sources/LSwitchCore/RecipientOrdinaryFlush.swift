#if DEBUG
import CoreGraphics
import Dispatch
import Foundation

struct RecipientOrdinaryTiming {
    let deadline: UInt64
    var now: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    /// Системный driver всегда использует timer; модель вызывает pollRetention управляемо.
    var automaticPolling = true
}

/// App-owner удерживает transport до потребления terminalProof. State хранит только weak ссылку и marker metadata.
final class RecipientOrdinaryFlush: @unchecked Sendable {
    private enum Phase { case prepared, accepting, waiting, dispatching, terminal }
    let marker: RecipientOrdinaryMarker
    let capture: RecipientOrdinaryCapture
    let transport = ConversionOrdinaryTransport()
    private weak var state: RecipientTapDriverState?
    private let timing: RecipientOrdinaryTiming
    private var deadline: UInt64 { timing.deadline }
    private func now() -> UInt64 { timing.now() }
    private let lock = NSLock()
    private var phase = Phase.prepared
    private var claim: ConversionSafetyInputClaim?
    private var correction: ConversionRecoveryLayoutTransition?
    private var custody: OrdinaryInputCustody?
    private var terminal: OrdinaryTerminalProof?
    private var wakeConsumed = false
    private var wakeInFlight = false
    private var wakeAttempted = false
    private var pendingProof: OrdinaryTerminalProof?
    private var pendingResult: ConversionOrdinaryTransportResult?
    private var retentionTimer: DispatchSourceTimer?

    init(
        capture: RecipientOrdinaryCapture, state: RecipientTapDriverState,
        marker: RecipientOrdinaryMarker, timing: RecipientOrdinaryTiming
    ) {
        self.capture = capture
        self.state = state
        self.marker = marker
        self.timing = .init(deadline: min(timing.deadline, capture.attachment.port.holdDeadline),
                            now: timing.now, automaticPolling: timing.automaticPolling)
    }

    var terminalProof: OrdinaryTerminalProof? {
        lock.lock()
        defer { lock.unlock() }
        return terminal
    }

    @MainActor
    func accept(
        correction: ConversionRecoveryLayoutTransition?, claimOwnership: () -> ConversionSafetyInputClaim?
    ) -> ConversionOrdinaryAcceptance {
        accept(correction: correction, claimOwnership: claimOwnership, postWake: { [weak state] event in
            guard let state, SystemProcessIdentity.isCurrent(state.bridge.capturedSenderIdentity),
                  SystemProcessIdentity.isCurrent(state.bridge.capturedTargetIdentity) else { return false }
            event.postToPid(state.bridge.processID)
            return true
        })
    }

    @MainActor
    func accept(
        correction: ConversionRecoveryLayoutTransition?,
        claimOwnership: () -> ConversionSafetyInputClaim?,
        postWake: (CGEvent) -> Bool
    ) -> ConversionOrdinaryAcceptance {
        guard !Task.isCancelled, now() < deadline, state?.permitsMutation == true, capture.isCurrent,
              let wake = marker.prepareEvent() else { return .refused }
        lock.lock()
        guard phase == .prepared else { lock.unlock(); return .refused }
        phase = .accepting
        lock.unlock()
        // Единственный MainActor claim вызывается вне transport/state/admission locks.
        guard let claim = claimOwnership(), claim.owner == .ordinaryDelivery,
              claim.operation == capture.scope.binding.scope.operation else { return .refused }
        lock.lock()
        self.claim = claim
        self.correction = correction
        phase = .waiting
        lock.unlock()
        startRetentionTimer()
        guard !Task.isCancelled, now() < deadline, state?.permitsMutation == true, capture.isCurrent,
              marker.matches(type: .keyUp, event: wake), reserveWakeSubmission() else {
            transport.requestRetention()
            return .accepted(transport)
        }
        let posted = postWake(wake)
        if !posted { transport.requestRetention() }
        finishWakeSubmission()
        return .accepted(transport)
    }

    private func reserveWakeSubmission() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .waiting, !wakeAttempted, !transport.retentionRequested else { return false }
        wakeAttempted = true
        wakeInFlight = true
        return true
    }

    private func finishWakeSubmission() {
        lock.lock()
        wakeInFlight = false
        terminal = pendingProof ?? terminal
        pendingProof = nil
        let result = pendingResult
        pendingResult = nil
        lock.unlock()
        if let result { transport.complete(result) }
    }

    /// Вызывается только из head callback до capture. Proxy не сохраняется ни в одном поле/escaping closure.
    func receiveWake(type: CGEventType, event: CGEvent, post: ((CGEvent) throws -> Void)?) {
        guard marker.owns(event) else { return }
        lock.lock()
        guard phase == .waiting, !wakeConsumed else { lock.unlock(); return }
        wakeConsumed = true
        lock.unlock()
        guard marker.matches(type: type, event: event), let post, canDispatch, capture.isCurrent else {
            transport.requestRetention()
            retireAndFinish(post: nil)
            return
        }
        retireAndFinish(post: post)
        // Отсутствующий proof означает активный local route. Позднего proxy не сохраняем/не повторяем.
        lock.lock()
        let retirementPending = phase == .waiting
        lock.unlock()
        if retirementPending { transport.requestRetention() }
    }

    /// Worker timer/stop: ни marker retry, ни native post; pending quiescence не объявляется завершением.
    func pollRetention() {
        lock.lock()
        let waiting = phase == .waiting
        lock.unlock()
        guard waiting else { return }
        if !canDispatch || !capture.isCurrent { transport.requestRetention() }
        if transport.retentionRequested { retireAndFinish(post: nil) }
    }

    func requestRetention() { transport.requestRetention() }

    private var canDispatch: Bool {
        !transport.retentionRequested && now() < deadline && state?.permitsOrdinaryFlush(self) == true
    }

    private func retireAndFinish(post: ((CGEvent) throws -> Void)?) {
        lock.lock()
        guard phase == .waiting, let claim else { lock.unlock(); return }
        phase = .dispatching
        let transition = correction
        lock.unlock()
        guard let taken = capture.takeCustody(claim: claim) else {
            lock.lock()
            phase = .waiting
            lock.unlock()
            return
        }
        lock.lock()
        custody = taken
        lock.unlock()
        let proof: OrdinaryTerminalProof?
        if let post, canDispatch {
            proof = taken.dispatch(
                policy: .init(deadline: deadline, now: now, canContinue: { self.canDispatch }),
                actions: .init(prepareCopy: { RecipientOrdinaryCorrection.prepare($0, transition: transition) },
                               post: post)
            )
        } else {
            taken.requestRetention()
            proof = taken.terminalProof
        }
        guard let proof else { return }
        publish(proof)
    }

    private func publish(_ proof: OrdinaryTerminalProof) {
        let released = proof.progress.failure == nil && state?.completeOrdinaryFlush(self, proof: proof) == true
        let published: OrdinaryTerminalProof
        if !released, proof.progress.failure == nil {
            guard let retained = proof.retainingAfterRouteRefusal() else {
                state?.markLost(.ordinaryDeliveryFailed)
                return
            }
            published = retained
        } else { published = proof }
        lock.lock()
        let result: ConversionOrdinaryTransportResult = released ? .locallyDispatched : .retainedFailure
        let waitingForWake = wakeInFlight
        if waitingForWake {
            pendingProof = published
            pendingResult = result
        } else { terminal = published }
        phase = .terminal
        let timer = retentionTimer
        retentionTimer = nil
        lock.unlock()
        timer?.cancel()
        if !released { state?.markLost(.ordinaryDeliveryFailed) }
        // Это локальный returned результат, не принятие renderer и не освобождение reservation в Coordinator.
        if !waitingForWake { transport.complete(result) }
    }

    /// После stop worker может уже исчезнуть. Один timer ждёт лишь RAM quiescence, без post/IPC.
    private func startRetentionTimer() {
        guard timing.automaticPolling else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.setEventHandler { [weak self] in self?.pollRetention() }
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        lock.lock()
        let shouldKeep = phase != .terminal
        if shouldKeep { retentionTimer = timer }
        lock.unlock()
        timer.resume()
        if !shouldKeep { timer.cancel() }
    }

    deinit { retentionTimer?.cancel() }
}
#endif
