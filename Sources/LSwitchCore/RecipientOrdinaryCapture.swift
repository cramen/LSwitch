#if DEBUG
import Foundation

/// Конкретный scoped capture. Этот объект не даёт нового ledger claim и не раскрывает held events.
final class RecipientOrdinaryCapture: @unchecked Sendable {
    let router: RecoveryCaptureRouter
    let attachment: RecoveryCaptureAttachment
    let scope: RecoveryCaptureScope
    private let lock = NSLock()
    private weak var activatedState: RecipientTapDriverState?
    private var activationBound = false

    init?(router: RecoveryCaptureRouter, attachment: RecoveryCaptureAttachment, scope: RecoveryOperationTarget) {
        guard attachment.policy == .recipientInput, attachment.port.scope.binding.scope == scope,
              attachment.port.scope.tapIdentifier == router.identifier,
              router.matchesCapture(scope: scope, policy: .recipientInput) else { return nil }
        self.router = router
        self.attachment = attachment
        self.scope = attachment.port.scope
    }

    var isCurrent: Bool {
        lock.lock()
        let state = activatedState
        lock.unlock()
        guard state?.permitsMutation == true else { return false }
        attachment.expire()
        return attachment.port.permitsMutation(for: scope) && state?.permitsMutation == true
    }

    /// Не вызывает state/port: публикация происходит под state lock в том же worker block.
    func bindActivation(_ state: RecipientTapDriverState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !activationBound, state.bridge.capturedScope == scope.binding.scope else { return false }
        activationBound = true
        activatedState = state
        return true
    }

    /// Повторяется только локальное ожидание quiescence. Закрытие не разрешает никакой native post.
    func takeCustody(claim: ConversionSafetyInputClaim) -> OrdinaryInputCustody? {
        guard router.beginRetirement(attachment),
              let seal = attachment.port.trySealForStorage(scope: scope),
              let proof = router.retiredProof(seal: seal),
              let custody = attachment.port.takeOrdinary(claim: claim, quiescence: proof) else { return nil }
        _ = router.detach(attachment)
        return custody
    }

    func invalidate() { attachment.invalidate(.interceptionStopped) }
}

/// Одноразовый запрос worker: cancellation нельзя отменить поздним выполнением блока run loop.
final class RecipientCaptureArming: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = true
    private var continuation: CheckedContinuation<Bool, Never>?
    private let state: RecipientTapDriverState
    private let capture: RecipientOrdinaryCapture
    private let activation: RecoveryRecipientActivation

    init(state: RecipientTapDriverState, capture: RecipientOrdinaryCapture, activation: RecoveryRecipientActivation) {
        self.state = state
        self.capture = capture
        self.activation = activation
    }

    func register(_ value: CheckedContinuation<Bool, Never>) {
        lock.lock()
        guard pending else { lock.unlock(); value.resume(returning: false); return }
        continuation = value
        lock.unlock()
    }

    func run() {
        lock.lock()
        guard pending else { lock.unlock(); return }
        // Worker block сериализован с callbacks; здесь нет capture/admission/read payload.
        let accepted = state.publishRecipientCapture(capture, activation: activation)
        pending = false
        let result = continuation
        continuation = nil
        lock.unlock()
        if !accepted { capture.invalidate() }
        result?.resume(returning: accepted)
    }

    func cancel() {
        lock.lock()
        let wasPending = pending
        pending = false
        let result = continuation
        continuation = nil
        lock.unlock()
        // Даже уже завершённый arm больше не допускает мутацию при отменённом ожидающем task.
        state.markLost(.stopped)
        if wasPending { activation.cancel() }
        result?.resume(returning: false)
    }

    func expireIfPending() {
        lock.lock()
        guard pending else { lock.unlock(); return }
        pending = false
        let result = continuation
        continuation = nil
        lock.unlock()
        state.markLost(.startupTimedOut)
        activation.cancel()
        result?.resume(returning: false)
    }
}
#endif
