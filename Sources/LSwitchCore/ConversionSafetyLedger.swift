import Foundation

/// Чистый журнал одной операции. Общий экземпляр сохраняет историю при оборачивании запросов.
/// Ни один метод не выполняет post, AX, clipboard, чтение часов или запись payload.
@MainActor
public final class ConversionSafetyLedger {
    public let operation: ConversionSafetyOperationToken
    public private(set) var decision: ConversionSafetyDecision?
    public private(set) var inputOwner: ConversionSafetyInputOwner = .transaction
    public private(set) var encounteredUnknown = false
    public private(set) var recordedCleanup: ConversionSafetyCleanupEvidence?

    private var entries: [ConversionSafetySubmissionToken: ConversionSafetyEntry] = [:]
    private var outstandingKeyDebt = Set<ConversionSafetySubmissionToken>()
    private var lastOrdinal: UInt64 = 0
    private var usesRecordedCleanup = false
    private var cleanupRevision: UInt64 = 0
    private var activeCleanupObservation: ConversionSafetyCleanupObservation?
    private var profile: ConversionSafetyProfileState?
    private var ordinaryDeliveryRefused = false

    public init(generation: UInt64) {
        self.operation = ConversionSafetyOperationToken(generation: generation)
    }

    init(generation: UInt64, profile: ConversionSafetyProfileBinding) {
        self.operation = ConversionSafetyOperationToken(generation: generation)
        self.profile = ConversionSafetyProfileState(binding: profile)
    }

    var profileBinding: ConversionSafetyProfileBinding? { profile?.binding }
    var hasProfileFault: Bool { profile?.fault != nil }
    var profileFault: ConversionSafetyProfileFault? { profile?.fault }
    var hasObservedProfileFinalState: Bool { profile?.finalStateObserved == true }
    var hasUnacceptedSubmissions: Bool {
        entries.values.contains { $0.resolution == nil && (profile == nil || !$0.observedUnderProfile) }
    }

    public var submissionCount: Int { entries.count }

    /// Только ещё не использованный token непосредственно перед native post; не разрешение replay.
    func isFreshSubmission(_ token: ConversionSafetySubmissionToken, kind: ConversionSafetySubmissionKind) -> Bool {
        guard decision == nil, token.operation == operation, let entry = entries[token] else { return false }
        return entry.kind == kind && entry.returned == nil && !entry.admitted && !entry.unknown
            && entry.resolution == nil && !entry.observedUnderProfile
    }
    public var hasEditorMutation: Bool { entries.values.contains { $0.kind.changesEditor } }
    public var hasUnresolvedSubmissions: Bool { entries.values.contains { $0.resolution == nil } }
    public var hasUnknownSubmissions: Bool { entries.values.contains { $0.unknown && $0.resolution == nil } }
    public var hasOutstandingKeyDebt: Bool { !outstandingKeyDebt.isEmpty }
    /// Исторический decision не является актуальным permit после отказа transport до claim.
    public var currentInputDisposition: ConversionSafetyInputDisposition? {
        ordinaryDeliveryRefused ? .recoveryRequired : decision?.input
    }

    public var permitsConfirmedResult: Bool {
        decision?.permitsConfirmedResult == true && !ordinaryDeliveryRefused
    }
    public var permitsOrdinarySubmission: Bool {
        decision == nil && !encounteredUnknown && !hasProfileFault && (profile == nil || !hasUnacceptedSubmissions)
    }

    /// Вызывается после подготовки/guards, но ДО setter/post. Токен не заменяет системный допуск.
    public func willSubmit(
        _ kind: ConversionSafetySubmissionKind, operation token: ConversionSafetyOperationToken
    ) -> ConversionSafetySubmissionToken? {
        guard permitsOrdinarySubmission, !kind.isCleanup,
              profile == nil || kind.changesEditor else { return nil }
        return append(kind, operation: token)
    }

    /// После unknown можно только журналировать cleanup; внешний canCleanup остаётся обязательным.
    public func willSubmitCleanup(
        _ kind: ConversionSafetySubmissionKind, operation token: ConversionSafetyOperationToken
    ) -> ConversionSafetySubmissionToken? {
        guard kind.isCleanup,
              profile == nil || (!hasProfileFault && !hasUnacceptedSubmissions && kind == .restoreSelection) else {
            return nil
        }
        return append(kind, operation: token)
    }

    /// Повторный/чужой callback не изменяет журнал; после finish доказательства не повышают disposition.
    @discardableResult
    public func observe(
        _ observation: ConversionSafetySubmissionObservation, for token: ConversionSafetySubmissionToken
    ) -> Bool {
        guard decision == nil, token.operation == operation, var entry = entries[token],
              entry.record(observation) else { return false }
        entries[token] = entry
        if observation == .unknown { encounteredUnknown = true }
        if observation == .unknown { recordProfileFault(.unknownSubmission, operation: operation) }
        if observation == .adapterReturned(false) { recordProfileFault(.writeRejected, operation: operation) }
        if observation == .preventedBeforeAdmission { profile?.invalidate() }
        if entry.kind.changesEditor, observation == .unknown || observation == .receiverCompleted {
            invalidateCleanup()
            profile?.invalidate()
        }
        return true
    }

    /// Обработка Down не доказывает отпускание клавиши. Отдельный факт не стирается cleanup/readback.
    /// Неподтверждённый баланс первой версии сохраняется до recovery без автоматического снятия.
    @discardableResult
    public func recordOutstandingKeyDebt(for token: ConversionSafetySubmissionToken) -> Bool {
        guard decision == nil, token.operation == operation, let entry = entries[token],
              entry.kind != .balancingRelease, entry.resolution != .preventedBeforeAdmission,
              outstandingKeyDebt.insert(token).inserted else { return false }
        encounteredUnknown = true
        recordProfileFault(.outstandingKeyDebt, operation: operation)
        return true
    }

    /// Adapter вызывает перед свежим полным чтением; success RPC обязателен, но недостаточен.
    func beginProfileObservation(
        step: ConversionSafetyProfileStep, submission: ConversionSafetySubmissionToken? = nil,
        binding: ConversionSafetyProfileBinding
    ) -> ConversionSafetyProfileObservation? {
        guard decision == nil, !hasProfileFault, binding == profile?.binding else { return nil }
        if let submission {
            guard submission.operation == operation, let entry = entries[submission],
                  step.matches(entry.kind), entry.returned == true, !entry.unknown,
                  entry.resolution == nil, !entry.observedUnderProfile else { return nil }
        } else {
            guard step == .finalState, !hasUnacceptedSubmissions,
                  entries.values.contains(where: { $0.kind == .text && $0.observedUnderProfile }) else { return nil }
        }
        return profile?.begin(operation: operation, submission: submission, step: step)
    }

    /// Не записывает receiverCompleted. Проверки текста/identity принадлежат принятому AX adapter.
    @discardableResult
    func observeUnderProfile(
        _ observation: ConversionSafetyProfileObservation, binding: ConversionSafetyProfileBinding
    ) -> Bool {
        guard decision == nil, observation.operation == operation, binding == profile?.binding else { return false }
        if let token = observation.submission {
            guard var entry = entries[token], !entry.observedUnderProfile, !entry.unknown,
                  entry.returned == true, entry.resolution == nil, observation.step.matches(entry.kind),
                  profile?.accept(observation) == true else { return false }
            entry.observedUnderProfile = true
            entries[token] = entry
            invalidateCleanup()
        } else {
            guard !hasUnacceptedSubmissions, profile?.accept(observation) == true else { return false }
        }
        return true
    }

    /// В режиме B отрицательный исход необратим даже после позднего completion или совпавшего snapshot.
    @discardableResult
    func recordProfileFault(
        _ reason: ConversionSafetyProfileFault, operation token: ConversionSafetyOperationToken
    ) -> Bool {
        guard token == operation, decision == nil, profile?.recordFault(reason) == true else { return false }
        encounteredUnknown = true
        invalidateCleanup()
        return true
    }

    /// Получается перед свежим чтением; одновременно действует не более одного наблюдения.
    public func beginCleanupObservation(
        operation token: ConversionSafetyOperationToken
    ) -> ConversionSafetyCleanupObservation? {
        guard token == operation, decision == nil, cleanupRevision < UInt64.max else { return nil }
        usesRecordedCleanup = true
        invalidateCleanup()
        let observation = ConversionSafetyCleanupObservation(operation: operation, revision: cleanupRevision)
        activeCleanupObservation = observation
        return observation
    }

    /// Запоздавший результат не подтверждает состояние после новой отправки или receiver completion.
    @discardableResult
    public func recordCleanup(
        _ evidence: ConversionSafetyCleanupEvidence, observation: ConversionSafetyCleanupObservation
    ) -> Bool {
        guard observation.operation == operation, decision == nil,
              activeCleanupObservation == observation else { return false }
        recordedCleanup = normalizedCleanup(evidence)
        activeCleanupObservation = nil
        if evidence == .recoveryUnconfirmed, hasEditorMutation {
            recordProfileFault(.cleanupUnconfirmed, operation: operation)
        }
        return true
    }

    /// При отсутствии нового наблюдения после инвалидации старое evidence не разрешает replay.
    public func finishUsingRecordedCleanup(
        operation token: ConversionSafetyOperationToken, text: ConversionSafetyTextEvidence,
        ordinaryRouteValid: Bool
    ) -> ConversionSafetyDecision? {
        guard token == operation, decision == nil else { return nil }
        usesRecordedCleanup = true
        return finish(operation: token, text: text, cleanup: .recoveryUnconfirmed,
                      ordinaryRouteValid: ordinaryRouteValid)
    }

    /// Cleanup и доставка независимы: observed caret не завершает pending/unknown submission.
    public func finish(
        operation token: ConversionSafetyOperationToken,
        text: ConversionSafetyTextEvidence,
        cleanup requestedCleanup: ConversionSafetyCleanupEvidence,
        ordinaryRouteValid: Bool
    ) -> ConversionSafetyDecision? {
        guard token == operation, decision == nil else { return nil }
        if text == .unknown { recordProfileFault(.unconfirmedResult, operation: operation) }
        // Старый аргумент поддержан только до opt-in в записываемое evidence.
        let currentCleanup = usesRecordedCleanup ? recordedCleanup ?? .recoveryUnconfirmed : requestedCleanup
        let cleanup = normalizedCleanup(currentCleanup)
        let replay = ordinaryRouteValid && !hasUnacceptedSubmissions && !hasOutstandingKeyDebt
            && cleanup != .recoveryUnconfirmed && !hasProfileFault
            && (profile == nil || !hasEditorMutation || hasObservedProfileFinalState)
        let hasCompletedText = entries.values.contains { $0.kind == .text && $0.resolution == .receiverCompleted }
        let acceptsText = profile == nil ? hasCompletedText : hasObservedProfileFinalState
        let confirmed = text == .confirmed && replay && acceptsText && !encounteredUnknown
        let result = ConversionSafetyDecision(
            operation: operation, text: text, cleanup: cleanup,
            input: replay ? .replayAuthorized : .recoveryRequired,
            permitsConfirmedResult: confirmed,
            verificationBasis: confirmed ? (profile == nil ? .receiverCompleted : .observedUnderProfile) : .unconfirmed
        )
        decision = result
        activeCleanupObservation = nil
        return result
    }

    /// Отменяет только ещё не использованное ordinary-разрешение. Не отменяет RPC/post и не выдаёт второй claim.
    @discardableResult
    func recordOrdinaryDeliveryRefusal(operation token: ConversionSafetyOperationToken) -> Bool {
        guard token == operation, decision?.input == .replayAuthorized, inputOwner == .transaction else { return false }
        ordinaryDeliveryRefused = true
        return true
    }

    /// Единственный claim определяет потребителя; он не утверждает, что события уже обработаны системой.
    public func claimInput(operation token: ConversionSafetyOperationToken) -> ConversionSafetyInputClaim? {
        guard token == operation, let disposition = currentInputDisposition, inputOwner == .transaction else {
            return nil
        }
        inputOwner = disposition == .replayAuthorized ? .ordinaryDelivery : .recovery
        return ConversionSafetyInputClaim(operation: operation, owner: inputOwner)
    }

    private func append(
        _ kind: ConversionSafetySubmissionKind, operation token: ConversionSafetyOperationToken
    ) -> ConversionSafetySubmissionToken? {
        guard token == operation, decision == nil, lastOrdinal < UInt64.max else { return nil }
        lastOrdinal += 1
        let submission = ConversionSafetySubmissionToken(operation: operation, ordinal: lastOrdinal)
        entries[submission] = ConversionSafetyEntry(kind: kind)
        profile?.invalidate()
        if kind.changesEditor { invalidateCleanup() }
        return submission
    }

    private func invalidateCleanup() {
        if cleanupRevision < UInt64.max { cleanupRevision += 1 }
        activeCleanupObservation = nil
        if usesRecordedCleanup { recordedCleanup = .recoveryUnconfirmed }
    }

    private func normalizedCleanup(_ evidence: ConversionSafetyCleanupEvidence) -> ConversionSafetyCleanupEvidence {
        guard hasEditorMutation else { return .noOwnedMutation }
        return evidence == .recoveredObserved ? .recoveredObserved : .recoveryUnconfirmed
    }
}

private struct ConversionSafetyEntry {
    enum Resolution { case receiverCompleted, preventedBeforeAdmission }

    let kind: ConversionSafetySubmissionKind
    var returned: Bool?
    var admitted = false
    var unknown = false
    var resolution: Resolution?
    var observedUnderProfile = false

    mutating func record(_ observation: ConversionSafetySubmissionObservation) -> Bool {
        switch observation {
        case .adapterReturned(let value): return recordReturn(value)
        case .admitted: return recordAdmission()
        case .receiverCompleted: return recordCompletion()
        case .preventedBeforeAdmission: return recordPrevention()
        case .unknown: return recordUnknown()
        }
    }

    private mutating func recordReturn(_ value: Bool) -> Bool {
        guard returned == nil else { return false }
        returned = value
        return true
    }

    private mutating func recordAdmission() -> Bool {
        guard !admitted, resolution != .preventedBeforeAdmission else { return false }
        admitted = true
        return true
    }

    private mutating func recordCompletion() -> Bool {
        guard resolution == nil else { return false }
        admitted = true
        resolution = .receiverCompleted
        return true
    }

    private mutating func recordPrevention() -> Bool {
        guard !admitted, resolution == nil, !observedUnderProfile else { return false }
        resolution = .preventedBeforeAdmission
        return true
    }

    private mutating func recordUnknown() -> Bool {
        guard !unknown, resolution == nil else { return false }
        unknown = true
        return true
    }
}
