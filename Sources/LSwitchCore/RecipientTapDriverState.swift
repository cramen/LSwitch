#if DEBUG
import CoreGraphics
import Foundation

public enum RecipientTapDriverLoss: String, Equatable, Sendable {
    case permissionUnavailable, identityChanged, startupFailed, startupTimedOut
    case tapDisabled, tapUnavailable, peerEOF, observationLimit, eventShapeMismatch, stopped
}

public enum RecipientTapDriverObservation: String, Equatable, Sendable {
    case ownDownAllowed, ownReleaseAllowed, ownDownBlocked, ownReleaseBlocked
    case ownDownAtTail, ownReleaseAtTail, unmatchedDownAllowed, unmatchedDownBlocked
    case unmatchedDownAtTail, unmatchedReleaseAtTail
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
    public let observationsTruncated: Bool
    public let observations: [RecipientTapDriverObservation]
}

/// State не владеет worker/driver. Callback и protected detach используют один lock, без admission/IPC.
final class RecipientTapDriverState: @unchecked Sendable {
    static let maximumObservations = 256
    let bridge: RecoveryRecipientProbeBridge
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
    private var truncated = false
    private var observations: [RecipientTapDriverObservation] = []

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

    var isProtectionAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return healthyLocked && bridge.snapshot.protectionAvailable
    }

    var permitsMutation: Bool {
        lock.lock()
        defer { lock.unlock() }
        let current = bridge.snapshot
        return healthyLocked && current.protectionAvailable && current.phase == "protected"
            && !current.handoverRequested
    }

    /// Не сохраняет body. Вызывающий выполняет только scoped buffer.detach, уже после admission.seal.
    func withProtection(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard healthyLocked, bridge.snapshot.protectionAvailable else { return }
        body()
    }

    /// Единственный системный вход callback: не читает Unicode и shape чужого события.
    func observe(type: CGEventType, event: CGEvent, isHead: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            disableNotifications = increment(disableNotifications)
            if isHead { headEnabled = false } else { tailEnabled = false }
            markLostLocked(.tapDisabled)
            return true
        }
        guard type == .keyDown || type == .keyUp else { return true }
        let sender = event.getIntegerValueField(.eventSourceUnixProcessID)
        let marker = event.getIntegerValueField(.eventSourceUserData)
        let owned = bridge.owns(senderPID: sender, marker: marker)
        guard isHead else {
            tailObserved = increment(tailObserved)
            recordTailLocked(owned: owned, isDown: type == .keyDown)
            return true
        }
        if owned { return observeOwnedLocked(event, sender: sender, marker: marker) }
        guard type == .keyDown else { headAllowed = increment(headAllowed); return true }
        let decision = bridge.observeUnmatchedTargetDown()
        recordHeadLocked(decision.allowsEvent, observation: decision.allowsEvent
                         ? .unmatchedDownAllowed : .unmatchedDownBlocked)
        bridge.recordCallbackReturn(decision, returnedNil: !decision.allowsEvent)
        return decision.allowsEvent
    }

    var snapshot: RecipientTapDriverSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let current = bridge.snapshot
        return .init(workerRunning: running, headEnabled: headEnabled, tailEnabled: tailEnabled,
                     protectionAvailable: healthyLocked && current.protectionAvailable,
                     permitsMutation: healthyLocked && current.protectionAvailable
                        && current.phase == "protected" && !current.handoverRequested,
                     cleanupCompleted: cleaned, loss: loss, headAllowed: headAllowed, headBlocked: headBlocked,
                     tailObserved: tailObserved, disableNotifications: disableNotifications,
                     observationsTruncated: truncated, observations: observations)
    }

    private var healthyLocked: Bool { running && headEnabled && tailEnabled && loss == nil && !cleaned }

    private func observeOwnedLocked(_ event: CGEvent, sender: Int64, marker: Int64) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp,
              let keyCode = UInt16(exactly: event.getIntegerValueField(.keyboardEventKeycode)) else {
            markLostLocked(.eventShapeMismatch)
            headBlocked = increment(headBlocked)
            return false
        }
        let isDown = event.type == .keyDown
        let decision = bridge.observeOwn(
            senderPID: sender, marker: marker, phase: isDown ? .keyDown : .keyUp,
            keyCode: keyCode,
            modifierFlags: event.flags.rawValue
        )
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
