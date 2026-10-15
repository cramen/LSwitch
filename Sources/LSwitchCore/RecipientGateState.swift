import Foundation

enum RecipientGatePhase: Equatable, Sendable { case prepared, protected, quarantined, closed, lost }
enum RecipientGateRoute: Equatable, Sendable { case allow, block }

struct RecipientGateDecision: Equatable, Sendable {
    let route: RecipientGateRoute
    let admission: NativeDispatchAdmission?
    let handoverRequested: Bool
    /// Только чистое состояние. Реальную доступность tap дополнительно доказывает системный адаптер.
    let protectionAvailable: Bool
}

struct RecipientGateSnapshot: Equatable, Sendable {
    let phase: RecipientGatePhase
    let entryCount: Int
    let permitsMutation: Bool
    let handoverRequested: Bool
}

/// Будущий worker использует только этот owner: lock order gate → registry → marker allocator, без IPC/closures.
final class RecipientGateState: @unchecked Sendable {
    let scope: RecoveryOperationTarget
    private let registry: NativeDispatchRegistry
    private let lock = NSLock()
    private var phase = RecipientGatePhase.prepared
    private var protectionStarted = false
    private var handover = false

    init?(scope: RecoveryOperationTarget, markers: NativeDispatchMarkers? = NativeDispatchMarkers.shared) {
        guard let registry = NativeDispatchRegistry(scope: scope, markers: markers) else { return nil }
        self.scope = scope
        self.registry = registry
    }

    func activateProtection(scope expected: RecoveryOperationTarget) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard expected == scope, phase == .prepared, !registry.isClosed else { return false }
        protectionStarted = true
        phase = .protected
        return true
    }

    func reservePairs(_ shapes: [NativeDispatchPairShape], scope expected: RecoveryOperationTarget)
        -> [NativeDispatchPairReservation]? {
        lock.lock()
        defer { lock.unlock() }
        guard expected == scope, phase == .prepared || phase == .protected else { return nil }
        return registry.reservePairs(shapes)
    }

    func registerSubmitted(
        _ reservation: NativeDispatchReservation, token: ConversionSafetySubmissionToken,
        scope expected: RecoveryOperationTarget
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard protectionStarted, phase != .lost else { return false }
        return registry.registerSubmitted(reservation, token: token, scope: expected)
    }

    func observeOwned(marker: Int64, shape: NativeDispatchShape, target: RecoveryProcessIdentity)
        -> RecipientGateDecision {
        lock.lock()
        defer { lock.unlock() }
        let result = registry.observe(marker: marker, shape: shape, target: target)
        if case .admitted = result { return decision(.allow, admission: result) }
        if target == scope.target, protectionStarted { quarantineLocked() }
        return decision(.block, admission: result)
    }

    /// В protected-секции новый target Down блокируется до MainActor handover и не добавляется в сохранённый prefix.
    func observeUnmatchedTargetDown(target: RecoveryProcessIdentity) -> RecipientGateDecision {
        lock.lock()
        defer { lock.unlock() }
        guard target == scope.target, protectionStarted else { return decision(.allow) }
        quarantineLocked()
        return decision(.block)
    }

    func closeGeneration() {
        lock.lock()
        defer { lock.unlock() }
        registry.closeGeneration()
        if phase != .lost { phase = .closed }
    }

    func markLost() {
        lock.lock()
        defer { lock.unlock() }
        registry.markLost()
        phase = .lost
        handover = protectionStarted
    }

    func status(of reservation: NativeDispatchReservation) -> NativeDispatchStatus? {
        lock.lock()
        defer { lock.unlock() }
        return registry.status(of: reservation)
    }

    /// Проверка собственного source PID остаётся обязательной до этого metadata-only lookup.
    func ownsReservedMarker(_ marker: Int64, target: RecoveryProcessIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registry.ownsReservedMarker(marker, target: target)
    }

    var snapshot: RecipientGateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return .init(phase: phase, entryCount: registry.entryCount,
                     permitsMutation: phase == .protected && !registry.isClosed, handoverRequested: handover)
    }

    private func quarantineLocked() {
        registry.closeGeneration()
        if phase != .lost { phase = .quarantined }
        handover = true
    }

    private func decision(_ route: RecipientGateRoute, admission: NativeDispatchAdmission? = nil)
        -> RecipientGateDecision {
        .init(route: route, admission: admission, handoverRequested: handover,
              protectionAvailable: protectionStarted && phase != .lost)
    }
}
