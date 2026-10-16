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

    @MainActor
    @discardableResult
    public func refreshProtection() -> Bool {
        _ = worker.refreshHealth()
        return state.isProtectionAvailable
    }

    public func withProtection(_ body: () -> Void) { state.withProtection(body) }

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
