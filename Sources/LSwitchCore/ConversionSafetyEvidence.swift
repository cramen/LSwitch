import Foundation

/// Только факты о результате операции; пользовательский текст здесь не хранится.
public enum ConversionSafetyTextEvidence: Equatable, Sendable {
    case unchangedByOperation
    case confirmed
    case unknown
}

public enum ConversionSafetyCleanupEvidence: Equatable, Sendable {
    case noOwnedMutation
    case recoveredObserved
    case recoveryUnconfirmed
}

public enum ConversionSafetyInputDisposition: Equatable, Sendable {
    case replayAuthorized
    case recoveryRequired
}

/// Владелец полномочия на передачу очереди, а не подтверждение обработки событий редактором.
public enum ConversionSafetyInputOwner: Equatable, Sendable {
    case transaction
    case ordinaryDelivery
    case recovery
}

public enum ConversionSafetySubmissionKind: Equatable, Sendable {
    case selection
    case text
    case copy
    case restoreSelection
    case balancingRelease

    var changesEditor: Bool {
        self == .selection || self == .text || self == .restoreSelection
    }

    var isCleanup: Bool { self == .restoreSelection || self == .balancingRelease }
}

public enum ConversionSafetySubmissionObservation: Equatable, Sendable {
    /// Возврат API фиксируется отдельно и не подтверждает отсутствие либо завершение мутации.
    case adapterReturned(Bool)
    case admitted
    /// Требуется доказательство адаптера о завершении именно этой отправки, не обычный AX readback.
    case receiverCompleted
    /// Требуется доказанная окончательная блокировка до admission, не timeout или отмена Promise.
    case preventedBeforeAdmission
    case unknown
}

/// Identity журнала не позволяет токену другой операции закрыть совпавший номер поколения.
public struct ConversionSafetyOperationToken: Hashable, Sendable {
    public let generation: UInt64
    private let identity: UUID

    init(generation: UInt64) {
        self.generation = generation
        self.identity = UUID()
    }
}

public struct ConversionSafetySubmissionToken: Hashable, Sendable {
    public let operation: ConversionSafetyOperationToken
    public let ordinal: UInt64

    init(operation: ConversionSafetyOperationToken, ordinal: UInt64) {
        self.operation = operation
        self.ordinal = ordinal
    }
}

/// Одна проверка cleanup начинается до чтения и не переживает изменение revision журнала.
public struct ConversionSafetyCleanupObservation: Equatable, Sendable {
    public let operation: ConversionSafetyOperationToken
    private let revision: UInt64

    init(operation: ConversionSafetyOperationToken, revision: UInt64) {
        self.operation = operation
        self.revision = revision
    }
}

public struct ConversionSafetyDecision: Equatable, Sendable {
    public let operation: ConversionSafetyOperationToken
    public let text: ConversionSafetyTextEvidence
    public let cleanup: ConversionSafetyCleanupEvidence
    public let input: ConversionSafetyInputDisposition
    /// Разрешение публиковать подтверждённую замену не следует из разрешения доставить ввод.
    public let permitsConfirmedResult: Bool
}

/// Выдаётся одному потребителю; фактическое перемещение событий выполняет внешний владелец очереди.
public struct ConversionSafetyInputClaim: Equatable, Sendable {
    public let operation: ConversionSafetyOperationToken
    public let owner: ConversionSafetyInputOwner
}
