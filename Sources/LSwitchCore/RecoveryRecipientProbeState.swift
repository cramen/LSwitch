#if DEBUG
import Foundation

public enum RecoveryRecipientProbePhase: Hashable, Sendable { case keyDown, keyUp }

/// Решение Core не аутентифицирует sender и не подтверждает обработку редактором.
public struct RecoveryRecipientProbeDecision: Sendable {
    public let allowsEvent: Bool
    public let handoverRequested: Bool
    public let protectionAvailable: Bool
    public let admission: String
    let owner: UUID
    let nativeAdmission: NativeDispatchAdmission?
}

/// Только metadata; registry prevention и применённое ledger evidence показаны раздельно.
public struct RecoveryRecipientProbeSnapshot: Sendable {
    public let processID: Int32
    public let phase: String
    public let reservationCount: Int
    public let preparedCount: Int
    public let submittedCount: Int
    public let admittedCount: Int
    public let preventedCount: Int
    public let unresolvedCount: Int
    public let downStatus: String
    public let releaseStatus: String
    public let handoverRequested: Bool
    public let protectionAvailable: Bool
    public let lost: Bool
    public let lossCount: Int
    public let pendingObservationCount: Int
    public let overflowCount: Int
    public let callbackMismatchCount: Int
    public let sourceRejectedCount: Int
    public let markerRejectedCount: Int
    public let callbackAllowedCount: Int
    public let callbackBlockedCount: Int
    public let preflightRefusedCount: Int
    public let registrationRefusedCount: Int
    public let ledgerSubmissionCount: Int
    public let ledgerReturnedCount: Int
    public let ledgerAdmittedCount: Int
    public let ledgerPreventedCount: Int
    public let ledgerUnknownCount: Int
    public let ledgerUnresolvedCount: Int
    public let receiverCompleted = false
    public let replayAuthorized = false
    public let recoveryGateAccepted = false
}

struct RecoveryRecipientProbeObservation: Sendable {
    let token: ConversionSafetySubmissionToken
    let admitted: Bool
    let preventionEligible: Bool
}

struct RecoveryRecipientProbeLedgerCounts {
    var submissions = 0
    var returned = 0
    var admitted = 0
    var prevented = 0
    var unknown = 0
    var unresolved: Int { submissions - prevented }
}

struct RecoveryRecipientProbeLocalSnapshot {
    let pair: NativeDispatchPairReservation?
    let pending: Int
    let overflow: Int
    let mismatch: Int
    let sourceRejected: Int
    let markerRejected: Int
    let allowed: Int
    let blocked: Int
    let losses: Int
    let protectionStarted: Bool
    let preflightRefused: Int
    let registrationRefused: Int
    let ledger: RecoveryRecipientProbeLedgerCounts
}

/// Lock не удерживается при обращении к gate или MainActor ledger. Payload здесь не существует.
final class RecoveryRecipientProbeObservations: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumObservations = 256
    private var pair: NativeDispatchPairReservation?
    private var queue: [RecoveryRecipientProbeObservation] = []
    private var completed = Set<ConversionSafetySubmissionToken>()
    private var overflow = 0
    private var mismatch = 0
    private var sourceRejected = 0
    private var markerRejected = 0
    private var allowed = 0
    private var blocked = 0
    private var losses = 0
    private var protectionStarted = false
    private var preflightRefused = 0
    private var registrationRefused = 0
    private var ledger = RecoveryRecipientProbeLedgerCounts()

    var snapshot: RecoveryRecipientProbeLocalSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return .init(pair: pair, pending: queue.count, overflow: overflow, mismatch: mismatch,
                     sourceRejected: sourceRejected, markerRejected: markerRejected,
                     allowed: allowed, blocked: blocked, losses: losses, protectionStarted: protectionStarted,
                     preflightRefused: preflightRefused, registrationRefused: registrationRefused, ledger: ledger)
    }

    func publish(_ pair: NativeDispatchPairReservation) {
        lock.lock()
        self.pair = pair
        lock.unlock()
    }

    func recordLookup(sourceMatches: Bool, markerMatches: Bool) {
        lock.lock()
        if !sourceMatches { sourceRejected += 1 } else if !markerMatches { markerRejected += 1 }
        lock.unlock()
    }

    func recordLoss() {
        lock.lock()
        losses = 1
        lock.unlock()
    }

    func recordProtectionStarted() {
        lock.lock()
        protectionStarted = true
        lock.unlock()
    }

    func recordRegistrationRefusal(afterLedger: Bool) {
        lock.lock()
        if afterLedger { registrationRefused += 1 } else { preflightRefused += 1 }
        lock.unlock()
    }

    /// Вызывается только из ветки реального callback непосредственно перед return event/nil.
    /// false означает несовпадение маршрута или переполнение; владелец должен latch lost.
    func recordCallback(
        _ decision: RecoveryRecipientProbeDecision, returnedNil: Bool, expectedOwner: UUID
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard decision.owner == expectedOwner, returnedNil != decision.allowsEvent else {
            mismatch += 1
            return false
        }
        let observation: RecoveryRecipientProbeObservation?
        switch decision.nativeAdmission {
        case .some(.admitted(let token)):
            observation = .init(token: token, admitted: true, preventionEligible: false)
        case .some(.prevented(let token, _)):
            observation = .init(token: token, admitted: false, preventionEligible: decision.protectionAvailable)
        case .some(.rejected), .none:
            observation = nil
        }
        if let observation {
            if completed.contains(observation.token) { return true }
            guard queue.count < maximumObservations, completed.count < maximumObservations else {
                overflow += 1
                return false
            }
            completed.insert(observation.token)
            queue.append(observation)
        }
        if returnedNil { blocked += 1 } else { allowed += 1 }
        return true
    }

    func drain() -> [RecoveryRecipientProbeObservation] {
        lock.lock()
        defer { lock.unlock() }
        let result = queue
        queue.removeAll(keepingCapacity: true)
        return result
    }

    func updateLedger(_ counts: RecoveryRecipientProbeLedgerCounts) {
        lock.lock()
        ledger = counts
        lock.unlock()
    }
}
#endif
