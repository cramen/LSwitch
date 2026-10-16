#if DEBUG
import Darwin
import Foundation

/// DEBUG-мост к настоящему Core registry. Sender PID/marker являются проверками контекста, не аутентификацией.
/// Worker не читает Unicode, не вызывает proc_pidinfo и не обращается к MainActor ledger.
public final class RecoveryRecipientProbeBridge: @unchecked Sendable {
    public let processID: Int32
    public let senderProcessID: Int32
    private let owner = UUID()
    private let sender: RecoveryProcessIdentity
    private let target: RecoveryProcessIdentity
    private let scope: RecoveryOperationTarget
    private let gate: RecipientGateState
    private let observations = RecoveryRecipientProbeObservations()
    @MainActor private let ledger: ConversionSafetyLedger
    @MainActor private var tokens: [RecoveryRecipientProbePhase: ConversionSafetySubmissionToken] = [:]
    @MainActor private var returned = Set<RecoveryRecipientProbePhase>()
    @MainActor private var ledgerCounts = RecoveryRecipientProbeLedgerCounts()
    private let identityCheck: @MainActor @Sendable (RecoveryProcessIdentity) -> Bool

    var capturedTargetIdentity: RecoveryProcessIdentity { target }
    var capturedSenderIdentity: RecoveryProcessIdentity { sender }

    @MainActor
    init?(
        sender: RecoveryProcessIdentity, target: RecoveryProcessIdentity,
        ledger: ConversionSafetyLedger, gate: RecipientGateState,
        identityCheck: @escaping @MainActor @Sendable (RecoveryProcessIdentity) -> Bool = {
            SystemProcessIdentity.isCurrent($0)
        }
    ) {
        let scope = RecoveryOperationTarget(operation: ledger.operation, target: target)
        guard gate.scope == scope else { return nil }
        self.sender = sender
        self.target = target
        self.ledger = ledger
        self.gate = gate
        self.identityCheck = identityCheck
        processID = target.processID
        senderProcessID = sender.processID
        self.scope = scope
    }

    @MainActor
    public static func makeOwnProcess() -> RecoveryRecipientProbeBridge? {
        guard let target = SystemProcessIdentity.read(processID: getpid()) else { return nil }
        let ledger = ConversionSafetyLedger(generation: 1)
        let scope = RecoveryOperationTarget(operation: ledger.operation, target: target)
        guard let gate = RecipientGateState(scope: scope) else { return nil }
        return RecoveryRecipientProbeBridge(sender: target, target: target, ledger: ledger, gate: gate)
    }

    @MainActor
    public func preparePair(keyCode: UInt16, downFlags: UInt64, releaseFlags: UInt64) -> Bool {
        guard identitiesAreCurrent else { markLost(); return false }
        guard observations.snapshot.pair == nil else { return false }
        let shape = NativeDispatchPairShape(
            down: .init(phase: .keyDown, keyCode: keyCode, modifierFlags: downFlags),
            release: .init(phase: .keyUp, keyCode: keyCode, modifierFlags: releaseFlags)
        )
        guard let pair = gate.reservePairs([shape], scope: scope)?.first else { return false }
        observations.publish(pair)
        return true
    }

    /// App вызывает только после создания и проверки собственных head/tail taps; это не production prearm.
    @MainActor
    public func activateProtection() -> Bool {
        guard identitiesAreCurrent else { markLost(); return false }
        guard gate.activateProtection(scope: scope) else { return false }
        observations.recordProtectionStarted()
        return true
    }

    public func marker(isDown: Bool) -> Int64? {
        guard let pair = observations.snapshot.pair else { return nil }
        return isDown ? pair.down.marker : pair.release.marker
    }

    /// Сначала sender PID, затем точный reserved marker. Shape вызывающий читает лишь после true.
    public func owns(senderPID: Int64, marker: Int64) -> Bool {
        let sourceMatches = senderPID == Int64(senderProcessID)
        let markerMatches = sourceMatches && gate.ownsReservedMarker(marker, target: target)
        observations.recordLookup(sourceMatches: sourceMatches, markerMatches: markerMatches)
        return markerMatches
    }

    /// Событие уже создано, marker/shape roundtrip и фокус проверены App. Следующий шаг — непосредственный post.
    @MainActor
    public func registerBeforePost(isDown: Bool) -> Bool {
        guard identitiesAreCurrent else {
            observations.recordRegistrationRefusal(afterLedger: false)
            markLost()
            return false
        }
        let phase: RecoveryRecipientProbePhase = isDown ? .keyDown : .keyUp
        guard tokens[phase] == nil, let pair = observations.snapshot.pair,
              mayRegister(isDown: isDown, pair: pair) else {
            observations.recordRegistrationRefusal(afterLedger: false)
            return false
        }
        let token = isDown
            ? ledger.willSubmit(.text, operation: ledger.operation)
            : ledger.willSubmitCleanup(.balancingRelease, operation: ledger.operation)
        guard let token else {
            observations.recordRegistrationRefusal(afterLedger: false)
            return false
        }
        ledgerCounts.submissions = ledger.submissionCount
        observations.updateLedger(ledgerCounts)
        let reservation = isDown ? pair.down : pair.release
        guard gate.registerSubmitted(reservation, token: token, scope: scope) else {
            // Gate мог закрыться между preflight и регистрацией. Post НЕ разрешён и не объявляется выполненным.
            observations.recordRegistrationRefusal(afterLedger: true)
            if ledger.observe(.unknown, for: token) { ledgerCounts.unknown += 1 }
            observations.updateLedger(ledgerCounts)
            markLost()
            return false
        }
        tokens[phase] = token
        return true
    }

    @MainActor
    public func recordPostReturned(isDown: Bool) {
        let phase: RecoveryRecipientProbePhase = isDown ? .keyDown : .keyUp
        guard let token = tokens[phase], returned.insert(phase).inserted else { return }
        // CGEvent post имеет void-return: это лишь факт возврата вызова, не delivery/renderer ACK.
        if ledger.observe(.adapterReturned(true), for: token) { ledgerCounts.returned += 1 }
        observations.updateLedger(ledgerCounts)
    }

    public func observeOwn(
        senderPID: Int64, marker: Int64, phase: RecoveryRecipientProbePhase,
        keyCode: UInt16, modifierFlags: UInt64
    ) -> RecoveryRecipientProbeDecision {
        guard owns(senderPID: senderPID, marker: marker) else {
            markLost()
            return .init(allowsEvent: false, handoverRequested: gate.snapshot.handoverRequested,
                         protectionAvailable: false, admission: "header_rejected", owner: owner, nativeAdmission: nil)
        }
        let shape = NativeDispatchShape(phase: phase == .keyDown ? .keyDown : .keyUp,
                                        keyCode: keyCode, modifierFlags: modifierFlags)
        return decision(gate.observeOwned(marker: marker, shape: shape, target: target))
    }

    public func observeUnmatchedTargetDown() -> RecoveryRecipientProbeDecision {
        decision(gate.observeUnmatchedTargetDown(target: target))
    }

    /// App обязан вызвать из той же ветки callback, которая немедленно возвращает event либо nil.
    public func recordCallbackReturn(_ decision: RecoveryRecipientProbeDecision, returnedNil: Bool) {
        if !observations.recordCallback(decision, returnedNil: returnedNil, expectedOwner: owner) { markLost() }
    }

    public func closeGeneration() { gate.closeGeneration() }

    public func markLost() {
        gate.markLost()
        observations.recordLoss()
    }

    public var permitsMutation: Bool { gate.snapshot.permitsMutation }

    public var isProtectionAvailable: Bool {
        observations.snapshot.protectionStarted && gate.snapshot.phase != .lost
    }

    @MainActor
    private var identitiesAreCurrent: Bool { identityCheck(sender) && identityCheck(target) }

    /// Только MainActor. Disable/lost/timer сами не создают observation и не завершают pending submission.
    @MainActor
    @discardableResult
    public func drainObservations() -> RecoveryRecipientProbeSnapshot {
        ledgerCounts.submissions = ledger.submissionCount
        for observation in observations.drain() {
            if observation.admitted {
                if ledger.observe(.admitted, for: observation.token) { ledgerCounts.admitted += 1 }
            } else if observation.preventionEligible, gate.snapshot.phase != .lost {
                if ledger.observe(.preventedBeforeAdmission, for: observation.token) { ledgerCounts.prevented += 1 }
            } else if ledger.observe(.unknown, for: observation.token) {
                // Потерянный tap не доказывает предотвращение даже при позднем nil-callback.
                ledgerCounts.unknown += 1
            }
        }
        observations.updateLedger(ledgerCounts)
        return snapshot
    }

    /// Диагностический срез отдельных locked reads, не атомарный permit для новой отправки.
    public var snapshot: RecoveryRecipientProbeSnapshot {
        let local = observations.snapshot
        let transport = gate.snapshot
        let down = local.pair.flatMap { gate.status(of: $0.down) }
        let release = local.pair.flatMap { gate.status(of: $0.release) }
        let states = [Self.statusName(down), Self.statusName(release)]
        return .init(
            processID: processID, phase: Self.phaseName(transport.phase), reservationCount: transport.entryCount,
            preparedCount: states.filter { $0 == "prepared" }.count,
            submittedCount: states.filter { $0 == "submitted" }.count,
            admittedCount: states.filter { $0 == "admitted" }.count,
            preventedCount: states.filter { $0 == "prevented" }.count,
            unresolvedCount: states.filter { $0 == "submitted" || $0 == "admitted" }.count,
            downStatus: states[0], releaseStatus: states[1], handoverRequested: transport.handoverRequested,
            protectionAvailable: local.protectionStarted && transport.phase != .lost,
            lost: transport.phase == .lost, lossCount: local.losses, pendingObservationCount: local.pending,
            overflowCount: local.overflow, callbackMismatchCount: local.mismatch,
            sourceRejectedCount: local.sourceRejected, markerRejectedCount: local.markerRejected,
            callbackAllowedCount: local.allowed, callbackBlockedCount: local.blocked,
            preflightRefusedCount: local.preflightRefused, registrationRefusedCount: local.registrationRefused,
            ledgerSubmissionCount: local.ledger.submissions, ledgerReturnedCount: local.ledger.returned,
            ledgerAdmittedCount: local.ledger.admitted, ledgerPreventedCount: local.ledger.prevented,
            ledgerUnknownCount: local.ledger.unknown, ledgerUnresolvedCount: local.ledger.unresolved
        )
    }

    private func mayRegister(isDown: Bool, pair: NativeDispatchPairReservation) -> Bool {
        let phase = gate.snapshot.phase
        guard phase != .lost else { return false }
        if isDown { return gate.snapshot.permitsMutation }
        switch gate.status(of: pair.down) {
        case .some(.admitted): return true
        case .some(.submitted): return phase == .protected
        default: return false
        }
    }

    private func decision(_ value: RecipientGateDecision) -> RecoveryRecipientProbeDecision {
        let label: String
        switch value.admission {
        case .some(.admitted): label = "admitted"
        case .some(.prevented): label = "prevented"
        case .some(.rejected): label = "rejected"
        case .none: label = "none"
        }
        return .init(allowsEvent: value.route == .allow, handoverRequested: value.handoverRequested,
                     protectionAvailable: value.protectionAvailable, admission: label,
                     owner: owner, nativeAdmission: value.admission)
    }

    private static func statusName(_ value: NativeDispatchStatus?) -> String {
        switch value {
        case .some(.prepared): return "prepared"
        case .some(.submitted): return "submitted"
        case .some(.admitted): return "admitted"
        case .some(.prevented): return "prevented"
        case .none: return "unreserved"
        }
    }

    private static func phaseName(_ value: RecipientGatePhase) -> String {
        switch value {
        case .prepared: return "prepared"
        case .protected: return "protected"
        case .quarantined: return "quarantined"
        case .closed: return "closed"
        case .lost: return "lost"
        }
    }
}
#endif
