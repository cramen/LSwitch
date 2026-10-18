#if DEBUG
import CoreGraphics
import Foundation

public enum RecipientTapDriverLoss: String, Equatable, Sendable {
    case permissionUnavailable, identityChanged, startupFailed, startupTimedOut
    case tapDisabled, tapUnavailable, peerEOF, observationLimit, eventShapeMismatch, stopped, ordinaryDeliveryFailed
}

public enum RecipientTapDriverObservation: String, Equatable, Sendable {
    case ownDownAllowed, ownReleaseAllowed, ownDownBlocked, ownReleaseBlocked
    case ownDownAtTail, ownReleaseAtTail, unmatchedDownAllowed, unmatchedDownBlocked
    case unmatchedDownAtTail, unmatchedReleaseAtTail
    case fixtureDownSuppressed, fixtureReleaseSuppressed
    case targetInputAllowed, targetInputBlocked, targetInputAtTail, captureSuppressed
}

/// Только ограниченные метаданные. Enabled-поля — последний health sample, не новый системный запрос.
public struct RecipientTapDriverSnapshot: Sendable {
    public let workerRunning: Bool
    public let headEnabled: Bool
    public let tailEnabled: Bool
    public let protectionAvailable: Bool
    public let permitsMutation: Bool
    public let cleanupCompleted: Bool
    public let loss: RecipientTapDriverLoss?
    public let headAllowed: Int
    public let headBlocked: Int
    public let tailObserved: Int
    public let disableNotifications: Int
    public let fixtureSuppressed: Int
    public let captureSuppressed: Int
    public let mouseButtonsReleased: Bool
    public let eventCounters: RecipientEventCounters
    public let observationsTruncated: Bool
    public let observations: [RecipientTapDriverObservation]
}

/// State не владеет worker/driver. Callback и protected detach используют один lock, без admission/IPC.
final class RecipientTapDriverState: @unchecked Sendable {
    static let maximumObservations = 256
    let bridge: RecoveryRecipientProbeBridge
    let captureEndpoint = RecipientTapCaptureEndpoint()
    private let lock = NSLock()
    private var running = false
    private var headEnabled = false
    private var tailEnabled = false
    private var cleaned = false
    private var loss: RecipientTapDriverLoss?
    private var headAllowed = 0
    private var headBlocked = 0
    private var tailObserved = 0
    private var disableNotifications = 0
    private var fixtureSuppressed = 0
    private var captureSuppressed = 0
    private var mouseButtonsReleased = true
    private var forwardedButtons = Set<Int>()
    private var forwardedModifiers: CGEventFlags = []
    private var eventAllowed = [Int](repeating: 0, count: RecipientEventKind.allCases.count)
    private var eventBlocked = [Int](repeating: 0, count: RecipientEventKind.allCases.count)
    private var eventTail = [Int](repeating: 0, count: RecipientEventKind.allCases.count)
    private var eventCaptured = [Int](repeating: 0, count: RecipientEventKind.allCases.count)
    private var truncated = false
    private var observations: [RecipientTapDriverObservation] = []
    private weak var ordinaryFlush: RecipientOrdinaryFlush?
    private var ordinaryMarker: RecipientOrdinaryMarker?
    private var ordinaryPassThrough = false

    init(bridge: RecoveryRecipientProbeBridge) { self.bridge = bridge }

    func recordInstallation(head: Bool, tail: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !cleaned else { return }
        running = true
        headEnabled = head
        tailEnabled = tail
        if !head || !tail { markLostLocked(.startupFailed) }
    }

    func recordHealth(head: Bool, tail: Bool, identityMatches: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !cleaned else { return }
        headEnabled = head
        tailEnabled = tail
        if !identityMatches { markLostLocked(.identityChanged) }
        if !head || !tail { markLostLocked(.tapUnavailable) }
    }

    func markLost(_ reason: RecipientTapDriverLoss) {
        lock.lock()
        markLostLocked(reason)
        lock.unlock()
    }

    func recordCleanup() {
        lock.lock()
        defer { lock.unlock() }
        markLostLocked(.stopped)
        running = false
        headEnabled = false
        tailEnabled = false
        cleaned = true
    }

    var workerReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return healthyLocked
    }

    func recordPhysicalButtons(released: Bool) {
        lock.lock()
        mouseButtonsReleased = released
        lock.unlock()
    }

    var canArmProtection: Bool {
        lock.lock()
        defer { lock.unlock() }
        return healthyLocked && mouseButtonsReleased && forwardedButtons.isEmpty && bridge.snapshot.phase == "prepared"
    }

    /// Identity preflight уже завершён снаружи. Проверка down-состояния и activation неделимы для callback.
    func activateProtection(_ activation: RecoveryRecipientActivation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard bridge.ownsActivation(activation) else { return false }
        guard healthyLocked, mouseButtonsReleased, forwardedButtons.isEmpty else {
            activation.cancel()
            return false
        }
        return bridge.commitActivation(activation)
    }

    /// Только один worker block: публикация endpoint не может перемежаться с callback на том же run loop.
    func publishRecipientCapture(_ capture: RecipientOrdinaryCapture, activation: RecoveryRecipientActivation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard bridge.ownsActivation(activation), capture.scope.binding.scope == bridge.capturedScope,
              healthyLocked, mouseButtonsReleased, forwardedButtons.isEmpty,
              captureEndpoint.bindRecipientInput(router: capture.router, scope: bridge.capturedScope),
              capture.bindActivation(self) else {
            activation.cancel()
            return false
        }
        return bridge.commitActivation(activation)
    }

    func installOrdinaryFlush(_ flush: RecipientOrdinaryFlush) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard healthyLocked, ordinaryMarker == nil, !ordinaryPassThrough,
              flush.capture.scope.binding.scope == bridge.capturedScope,
              flush.marker.sourcePID == bridge.senderProcessID,
              !bridge.owns(senderPID: Int64(flush.marker.sourcePID), marker: flush.marker.value) else { return false }
        ordinaryFlush = flush
        ordinaryMarker = flush.marker
        return true
    }

    func permitsOrdinaryFlush(_ flush: RecipientOrdinaryFlush) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ordinaryFlush === flush && !ordinaryPassThrough && healthyLocked && bridge.permitsMutation
    }

    func completeOrdinaryFlush(_ flush: RecipientOrdinaryFlush, proof: OrdinaryTerminalProof) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard ordinaryFlush === flush, !ordinaryPassThrough, healthyLocked, bridge.permitsMutation,
              proof.scope == flush.capture.scope, proof.progress.failure == nil,
              proof.progress.attemptedPosts == proof.progress.totalEvents,
              proof.progress.returnedPosts == proof.progress.totalEvents,
              !flush.transport.retentionRequested else { return false }
        bridge.closeGeneration()
        ordinaryPassThrough = true
        return true
    }

    var isProtectionAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !ordinaryPassThrough && healthyLocked && bridge.snapshot.protectionAvailable
    }

    var permitsMutation: Bool {
        lock.lock()
        defer { lock.unlock() }
        let current = bridge.snapshot
        return !ordinaryPassThrough && healthyLocked && current.protectionAvailable && current.phase == "protected"
            && !current.handoverRequested
    }

    /// Не сохраняет body. Вызывающий выполняет только scoped buffer.detach, уже после admission.seal.
    func withProtection(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !ordinaryPassThrough, healthyLocked, bridge.snapshot.protectionAvailable else { return }
        body()
    }

    /// Только явный fixture endpoint может читать payload. Его admission не вызывается под state lock.
    func observe(
        type: CGEventType, event: CGEvent, isHead: Bool, postOrdinary: ((CGEvent) throws -> Void)? = nil
    ) -> Bool {
        if isHead, let decision = observeOrdinary(type: type, event: event, post: postOrdinary) { return decision }
        if isHead, captureEndpoint.route(type: type, event: event) == .suppress {
            recordCaptureSuppression(type: type)
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            disableNotifications = increment(disableNotifications)
            if isHead { headEnabled = false } else { tailEnabled = false }
            markLostLocked(.tapDisabled)
            return true
        }
        guard let kind = RecipientEventKind(eventType: type) else { return true }
        let sender = event.getIntegerValueField(.eventSourceUnixProcessID)
        let marker = event.getIntegerValueField(.eventSourceUserData)
        let owned = bridge.owns(senderPID: sender, marker: marker)
        guard isHead else {
            tailObserved = increment(tailObserved)
            Self.incrementKind(kind, in: &eventTail)
            if owned, let shape = NativeDispatchShape.readKeyboard(event) {
                recordTailLocked(owned: true, isDown: shape.phase.isDown)
            } else if type == .keyDown || type == .keyUp {
                recordTailLocked(owned: owned, isDown: type == .keyDown)
            } else {
                appendLocked(.targetInputAtTail)
            }
            return true
        }
        let allowed = observeHeadLocked(kind, event: event, owned: owned, sender: sender, marker: marker)
        if allowed { Self.incrementKind(kind, in: &eventAllowed) } else { Self.incrementKind(kind, in: &eventBlocked) }
        return allowed
    }

    var snapshot: RecipientTapDriverSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let current = bridge.snapshot
        return .init(workerRunning: running, headEnabled: headEnabled, tailEnabled: tailEnabled,
                     protectionAvailable: !ordinaryPassThrough && healthyLocked && current.protectionAvailable,
                     permitsMutation: healthyLocked && current.protectionAvailable
                        && current.phase == "protected" && !current.handoverRequested,
                     cleanupCompleted: cleaned, loss: loss, headAllowed: headAllowed, headBlocked: headBlocked,
                     tailObserved: tailObserved, disableNotifications: disableNotifications,
                     fixtureSuppressed: fixtureSuppressed,
                     captureSuppressed: captureSuppressed, mouseButtonsReleased: mouseButtonsReleased,
                     eventCounters: .init(allowed: eventAllowed, blocked: eventBlocked,
                                          tail: eventTail, captured: eventCaptured),
                     observationsTruncated: truncated, observations: observations)
    }

}

extension RecipientTapDriverState {
    private var healthyLocked: Bool { running && headEnabled && tailEnabled && loss == nil && !cleaned }

    /// Тот же marker tombstone остаётся после исчезновения weak owner. Никаких payload reads под state lock.
    private func observeOrdinary(
        type: CGEventType, event: CGEvent, post: ((CGEvent) throws -> Void)?
    ) -> Bool? {
        lock.lock()
        let owned = ordinaryMarker?.owns(event) == true
        let flush = ordinaryFlush
        // Принятый normal route необратим: teardown старого tap не должен снова поглощать новый ввод.
        let pass = ordinaryPassThrough
        lock.unlock()
        if owned {
            flush?.receiveWake(type: type, event: event, post: post)
            return false
        }
        guard pass, RecipientEventKind(eventType: type) != nil else { return nil }
        let ownedNative = bridge.owns(senderPID: event.getIntegerValueField(.eventSourceUnixProcessID),
                                     marker: event.getIntegerValueField(.eventSourceUserData))
        return ownedNative ? nil : true
    }

    private func recordCaptureSuppression(type: CGEventType) {
        lock.lock()
        defer { lock.unlock() }
        captureSuppressed = increment(captureSuppressed)
        if let kind = RecipientEventKind(eventType: type) { Self.incrementKind(kind, in: &eventCaptured) }
        if captureEndpoint.isFixtureBinding {
            fixtureSuppressed = increment(fixtureSuppressed)
            appendLocked(type == .keyDown ? .fixtureDownSuppressed : .fixtureReleaseSuppressed)
        } else { appendLocked(.captureSuppressed) }
    }

    private func observeHeadLocked(
        _ kind: RecipientEventKind, event: CGEvent, owned: Bool, sender: Int64, marker: Int64
    ) -> Bool {
        if owned { return observeOwnedLocked(event, sender: sender, marker: marker) }
        let button = kind.mouseButton == nil ? nil
            : kind.checkedButtonNumber(event.getIntegerValueField(.mouseEventButtonNumber))
        guard kind.mouseButton == nil || button != nil else {
            markLostLocked(.eventShapeMismatch)
            recordHeadLocked(false, observation: .targetInputBlocked)
            return false
        }
        if kind == .keyRelease { headAllowed = increment(headAllowed); return true }
        if kind == .modifierChange, RecipientModifierChange.isClearing(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags, forwarded: forwardedModifiers
        ) {
            forwardedModifiers = RecipientModifierChange.tracked(event.flags)
            recordHeadLocked(true, observation: .targetInputAllowed)
            return true
        }
        let decision = bridge.observeUnmatchedTargetDown()
        if decision.allowsEvent { recordForwardedState(kind, event: event, button: button) }
        let allowed: RecipientTapDriverObservation = kind == .keyDown ? .unmatchedDownAllowed : .targetInputAllowed
        let blocked: RecipientTapDriverObservation = kind == .keyDown ? .unmatchedDownBlocked : .targetInputBlocked
        recordHeadLocked(decision.allowsEvent, observation: decision.allowsEvent ? allowed : blocked)
        bridge.recordCallbackReturn(decision, returnedNil: !decision.allowsEvent)
        return decision.allowsEvent
    }

    private func recordForwardedState(_ kind: RecipientEventKind, event: CGEvent, button: Int?) {
        if kind == .modifierChange {
            forwardedModifiers = RecipientModifierChange.tracked(event.flags)
        }
        if let button {
            if kind.isMouseDown { forwardedButtons.insert(button) }
            if kind.isMouseRelease { forwardedButtons.remove(button) }
        }
    }

    private static func incrementKind(_ kind: RecipientEventKind, in counts: inout [Int]) {
        guard let index = RecipientEventKind.allCases.firstIndex(of: kind) else { return }
        counts[index] = min(counts[index] + 1, maximumObservations)
    }

    private func observeOwnedLocked(_ event: CGEvent, sender: Int64, marker: Int64) -> Bool {
        guard let shape = NativeDispatchShape.readKeyboard(event) else {
            markLostLocked(.eventShapeMismatch)
            headBlocked = increment(headBlocked)
            return false
        }
        let isDown = shape.phase.isDown
        let decision = bridge.observeNativeShape(senderPID: sender, marker: marker, shape: shape)
        let observation: RecipientTapDriverObservation
        if decision.allowsEvent { observation = isDown ? .ownDownAllowed : .ownReleaseAllowed } else {
            observation = isDown ? .ownDownBlocked : .ownReleaseBlocked
        }
        recordHeadLocked(decision.allowsEvent, observation: observation)
        bridge.recordCallbackReturn(decision, returnedNil: !decision.allowsEvent)
        return decision.allowsEvent
    }

    private func recordTailLocked(owned: Bool, isDown: Bool) {
        if owned { appendLocked(isDown ? .ownDownAtTail : .ownReleaseAtTail) } else {
            appendLocked(isDown ? .unmatchedDownAtTail : .unmatchedReleaseAtTail)
        }
    }

    private func recordHeadLocked(_ allowed: Bool, observation: RecipientTapDriverObservation) {
        if allowed { headAllowed = increment(headAllowed) } else { headBlocked = increment(headBlocked) }
        appendLocked(observation)
    }

    private func appendLocked(_ observation: RecipientTapDriverObservation) {
        guard observations.count < Self.maximumObservations else {
            truncated = true
            markLostLocked(.observationLimit)
            return
        }
        observations.append(observation)
    }

    private func increment(_ value: Int) -> Int { min(value + 1, Self.maximumObservations) }

    private func markLostLocked(_ reason: RecipientTapDriverLoss) {
        if loss == nil { loss = reason }
        bridge.markLost()
    }
}
#endif
