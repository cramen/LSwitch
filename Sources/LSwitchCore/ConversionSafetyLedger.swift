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

    public init(generation: UInt64) {
        self.operation = ConversionSafetyOperationToken(generation: generation)
    }

    public var submissionCount: Int { entries.count }
    public var hasEditorMutation: Bool { entries.values.contains { $0.kind.changesEditor } }
    public var hasUnresolvedSubmissions: Bool { entries.values.contains { $0.resolution == nil } }
    public var hasUnknownSubmissions: Bool { entries.values.contains { $0.unknown && $0.resolution == nil } }
    public var hasOutstandingKeyDebt: Bool { !outstandingKeyDebt.isEmpty }
    public var permitsOrdinarySubmission: Bool { decision == nil && !encounteredUnknown }

    /// Вызывается после подготовки/guards, но ДО setter/post. Токен не заменяет системный допуск.
    public func willSubmit(
        _ kind: ConversionSafetySubmissionKind, operation token: ConversionSafetyOperationToken
    ) -> ConversionSafetySubmissionToken? {
        guard permitsOrdinarySubmission, !kind.isCleanup else { return nil }
        return append(kind, operation: token)
    }

    /// После unknown можно только журналировать cleanup; внешний canCleanup остаётся обязательным.
    public func willSubmitCleanup(
        _ kind: ConversionSafetySubmissionKind, operation token: ConversionSafetyOperationToken
    ) -> ConversionSafetySubmissionToken? {
        guard kind.isCleanup else { return nil }
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
        if entry.kind.changesEditor, observation == .unknown || observation == .receiverCompleted {
            invalidateCleanup()
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
        // Старый аргумент поддержан только до opt-in в записываемое evidence.
        let currentCleanup = usesRecordedCleanup ? recordedCleanup ?? .recoveryUnconfirmed : requestedCleanup
        let cleanup = normalizedCleanup(currentCleanup)
        let replay = ordinaryRouteValid && !hasUnresolvedSubmissions && !hasOutstandingKeyDebt
            && cleanup != .recoveryUnconfirmed
        let hasCompletedText = entries.values.contains { $0.kind == .text && $0.resolution == .receiverCompleted }
        let result = ConversionSafetyDecision(
            operation: operation, text: text, cleanup: cleanup,
            input: replay ? .replayAuthorized : .recoveryRequired,
            permitsConfirmedResult: text == .confirmed && replay && hasCompletedText && !encounteredUnknown
        )
        decision = result
        activeCleanupObservation = nil
        return result
    }

    /// Единственный claim определяет потребителя; он не утверждает, что события уже обработаны системой.
    public func claimInput(operation token: ConversionSafetyOperationToken) -> ConversionSafetyInputClaim? {
        guard token == operation, let decision, inputOwner == .transaction else { return nil }
        inputOwner = decision.input == .replayAuthorized ? .ordinaryDelivery : .recovery
        return ConversionSafetyInputClaim(operation: operation, owner: inputOwner)
    }

    private func append(
        _ kind: ConversionSafetySubmissionKind, operation token: ConversionSafetyOperationToken
    ) -> ConversionSafetySubmissionToken? {
        guard token == operation, decision == nil, lastOrdinal < UInt64.max else { return nil }
        lastOrdinal += 1
        let submission = ConversionSafetySubmissionToken(operation: operation, ordinal: lastOrdinal)
        entries[submission] = ConversionSafetyEntry(kind: kind)
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
        guard !admitted, resolution == nil else { return false }
        resolution = .preventedBeforeAdmission
        return true
    }

    private mutating func recordUnknown() -> Bool {
        guard !unknown, resolution == nil else { return false }
        unknown = true
        return true
    }
}
