import CoreGraphics
import Dispatch

/// Связь одного журнала и gate. Возврат post не закрывает submission и не подтверждает текст редактора.
@MainActor
final class NativeDispatchBinding {
    private let gate: RecipientGateState
    private let ledger: ConversionSafetyLedger
    private let isCurrent: () -> Bool
    private let identityIsCurrent: (RecoveryProcessIdentity) -> Bool
    private let post: (CGEvent, pid_t) -> Void
    private var consumed = Set<Int64>()
    private var dispatching = false

    func belongs(to ledger: ConversionSafetyLedger) -> Bool { self.ledger === ledger }

    func prepare(command: ClipboardCommand) -> NativePreparedBatch? {
        NativePreparedBatch.prepare(command: command, gate: gate)
    }

    func prepare(events: [CGEvent]) -> NativePreparedBatch? {
        NativePreparedBatch.prepare(events, gate: gate)
    }

    init?(
        gate: RecipientGateState, ledger: ConversionSafetyLedger,
        isCurrent: @escaping () -> Bool,
        identityIsCurrent: @escaping (RecoveryProcessIdentity) -> Bool = { SystemProcessIdentity.isCurrent($0) },
        post: @escaping (CGEvent, pid_t) -> Void = { event, target in
            event.timestamp = DispatchTime.now().uptimeNanoseconds
            event.postToPid(target)
        }
    ) {
        guard gate.scope.operation == ledger.operation, ledger.profileBinding == nil else { return nil }
        self.gate = gate
        self.ledger = ledger
        self.isCurrent = isCurrent
        self.identityIsCurrent = identityIsCurrent
        self.post = post
    }

    /// Все внешние guards вызываются до регистрации. Между registerSubmitted и post нет await/guard callback.
    /// Даже отказ после beforeSend оставляет token unknown: предотвращение не выдумывается без head callback.
    func send(
        _ packet: NativePreparedBatch.Packet, kind: ConversionSafetySubmissionKind,
        hooks: ConversionDispatchHooks, transport: ConversionDispatchReply.Transport
    ) -> Bool {
        guard !dispatching, !consumed.contains(packet.reservation.marker), matches(packet.shape, kind: kind),
              let event = packet.copyEvent() else { return false }
        dispatching = true
        defer { dispatching = false }
        guard permits(packet, kind: kind) else { return false }
        consumed.insert(packet.reservation.marker)
        guard let token = hooks.beforeSend(kind) else { return false }
        guard permits(packet, kind: kind), ledger.isFreshSubmission(token, kind: kind),
              gate.registerSubmitted(packet.reservation, token: token, scope: gate.scope) else {
            ledger.observe(.unknown, for: token)
            return false
        }
        post(event, gate.scope.target.processID)
        hooks.didReturn(.init(submission: token, transport: transport, status: nil))
        return true
    }

    private func permits(_ packet: NativePreparedBatch.Packet, kind: ConversionSafetySubmissionKind) -> Bool {
        if kind != .balancingRelease {
            guard !Task.isCancelled, isCurrent() else { return false }
        }
        guard identityIsCurrent(gate.scope.target), ledger.decision == nil else { return false }
        if kind != .balancingRelease, !gate.snapshot.permitsMutation { return false }
        if !kind.isCleanup, !ledger.permitsOrdinarySubmission { return false }
        return gate.status(of: packet.reservation) == .prepared
    }

    private func matches(_ shape: NativeDispatchShape, kind: ConversionSafetySubmissionKind) -> Bool {
        switch shape.phase {
        case .modifierDown: return kind == .modifier
        case .keyDown: return kind.changesEditor || kind == .copy
        case .modifierUp, .keyUp: return kind == .balancingRelease
        }
    }
}
