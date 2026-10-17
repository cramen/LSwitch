import CoreGraphics
import Foundation

public enum OrdinaryDeliveryFailure: Equatable, Sendable {
    case retentionRequested, deadlineExceeded, routeUnavailable, copyUnavailable, postFailed
}

/// Только локальные попытки transport. Returned не означает доставку редактору.
public struct OrdinaryDeliveryProgress: Equatable, Sendable {
    public let totalEvents: Int
    public let attemptedPosts: Int
    public let returnedPosts: Int
    public let failure: OrdinaryDeliveryFailure?
    public var possiblyAlreadyDelivered: Bool { attemptedPosts > 0 }
}

struct OrdinaryDispatchPolicy {
    let deadline: UInt64
    let now: () -> UInt64
    let canContinue: () -> Bool
}

/// Замыкания никогда не получают оригинал. copyAllowed — metadata-only граница для отказа allocation.
struct OrdinaryDispatchActions {
    var copyAllowed: (Int) -> Bool = { _ in true }
    var prepareCopy: (CGEvent) -> Bool = { _ in true }
    let post: (CGEvent) throws -> Void
}

fileprivate struct OrdinaryInputBinding {
    let scope: RecoveryCaptureScope
    let seal: RecoveryAdmissionSeal
    let claim: ConversionSafetyInputClaim
    let identifier = UUID()
}

/// Единственный владелец оригинала после ordinary claim. Никаких post из deinit или повторного dispatch.
final class OrdinaryInputCustody: @unchecked Sendable {
    private enum Phase { case ready, dispatching, terminal }
    private let binding: OrdinaryInputBinding
    private let lock = NSLock()
    private var originals: [CGEvent]?
    private var phase = Phase.ready
    private var retention = false
    private var attempted = 0
    private var returned = 0
    private var terminal: OrdinaryTerminalProof?

    private init(binding: OrdinaryInputBinding, events: [CGEvent]) {
        self.binding = binding
        originals = events
    }

    /// Неподделываемый transfer создаёт port после exact quiescence proof; проверки предшествуют raw claim.
    static func take(_ transfer: OrdinaryCaptureTransfer) -> OrdinaryInputCustody? {
        let scope = transfer.scope
        let seal = transfer.seal
        let claim = transfer.claim
        guard claim.owner == .ordinaryDelivery, claim.operation == scope.binding.scope.operation,
              seal.binding == scope.binding, transfer.token == scope.binding.hold,
              transfer.eventCount == seal.counts.events,
              transfer.eventCount <= PreparedRecoveryAdmission.maximumEvents,
              seal.counts.utf16Bytes <= PreparedRecoveryAdmission.maximumUTF16Bytes,
              let events = transfer.takeEvents() else { return nil }
        return .init(binding: .init(scope: scope, seal: seal, claim: claim), events: events)
    }

    var identifier: UUID { binding.identifier }

    var terminalProof: OrdinaryTerminalProof? {
        lock.lock()
        defer { lock.unlock() }
        return terminal
    }

    func requestRetention() {
        lock.lock()
        defer { lock.unlock() }
        guard phase != .terminal else { return }
        retention = true
        if phase == .ready { _ = finishLocked(.retentionRequested) }
    }

    /// Сначала все копии, затем один проход post. Closure вызовы находятся вне всех внутренних locks.
    func dispatch(policy: OrdinaryDispatchPolicy, actions: OrdinaryDispatchActions) -> OrdinaryTerminalProof? {
        lock.lock()
        guard phase == .ready, let originals else { lock.unlock(); return nil }
        phase = .dispatching
        lock.unlock()
        var copies: [CGEvent] = []
        for (index, original) in originals.enumerated() {
            if let reason = stopReason(policy) { return finish(reason) }
            guard actions.copyAllowed(index), let copied = original.copy(), copied !== original,
                  actions.prepareCopy(copied) else { return finish(.copyUnavailable) }
            if let reason = stopReason(policy) { return finish(reason) }
            copies.append(copied)
        }
        for copied in copies {
            if let reason = stopReason(policy) { return finish(reason) }
            guard beginAttempt() else { return finish(.retentionRequested) }
            do { try actions.post(copied) } catch { return finish(.postFailed) }
            lock.lock()
            returned += 1
            lock.unlock()
        }
        return finish(stopReason(policy))
    }

    /// После reservation текущий attempt может завершиться; retention запрещает следующие ordinals.
    private func beginAttempt() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .dispatching, !retention else { return false }
        attempted += 1
        return true
    }

    private func stopReason(_ policy: OrdinaryDispatchPolicy) -> OrdinaryDeliveryFailure? {
        lock.lock()
        let alreadyRetaining = retention
        lock.unlock()
        if alreadyRetaining { return .retentionRequested }
        let permitted = policy.canContinue()
        let now = policy.now()
        lock.lock()
        defer { lock.unlock() }
        if retention { return .retentionRequested }
        if now >= policy.deadline { return .deadlineExceeded }
        return permitted ? nil : .routeUnavailable
    }

    private func finish(_ reason: OrdinaryDeliveryFailure?) -> OrdinaryTerminalProof {
        lock.lock()
        defer { lock.unlock() }
        return finishLocked(reason)
    }

    private func finishLocked(_ reason: OrdinaryDeliveryFailure?) -> OrdinaryTerminalProof {
        if let terminal { return terminal }
        let failure = reason ?? (retention ? .retentionRequested : nil)
        let proof = OrdinaryTerminalProof(binding: binding, events: originals ?? [], progress: .init(
            totalEvents: binding.seal.counts.events, attemptedPosts: attempted,
            returnedPosts: returned, failure: failure
        ))
        originals = nil
        terminal = proof
        phase = .terminal
        return proof
    }
}

/// Создаётся только custody после quiescence. Payload остаётся private до одного проверенного consumer.
final class OrdinaryTerminalProof: @unchecked Sendable {
    private let binding: OrdinaryInputBinding
    let progress: OrdinaryDeliveryProgress
    private let lock = NSLock()
    private var events: [CGEvent]?

    fileprivate init(binding: OrdinaryInputBinding, events: [CGEvent], progress: OrdinaryDeliveryProgress) {
        self.binding = binding
        self.events = events
        self.progress = progress
    }

    var scope: RecoveryCaptureScope { binding.scope }
    var seal: RecoveryAdmissionSeal { binding.seal }
    var claim: ConversionSafetyInputClaim { binding.claim }
    var transportIdentifier: UUID { binding.identifier }

    func takeRetained(seal: RecoveryAdmissionSeal) -> [CGEvent]? {
        lock.lock()
        defer { lock.unlock() }
        guard binding.seal === seal, progress.failure != nil, let events else { return nil }
        self.events = nil
        return events
    }

    func consumeCompletion(seal: RecoveryAdmissionSeal) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard binding.seal === seal, events != nil, progress.failure == nil,
              progress.attemptedPosts == progress.totalEvents, progress.returnedPosts == progress.totalEvents else {
            return false
        }
        events = nil
        return true
    }
}
