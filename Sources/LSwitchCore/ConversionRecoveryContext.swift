import Foundation

/// Контекст factory не содержит текста редактора или удержанных событий.
@MainActor
public struct ConversionRecoveryContext {
    public let bundleID: String
    public let sourceLayout: Layout
    public let generation: UInt64
    public let startedAt: UInt64
    let admission: ConversionRecoveryAdmission
    var identifier: UUID { admission.identifier }
    let isCurrent: Converter.ContextCheck
    let canCleanup: Converter.ContextCheck
}

/// Коррекция применяется transport к доставляемым копиям, а не к исходной RAM-записи.
public struct ConversionRecoveryLayoutTransition: Equatable, Sendable {
    public let source: Layout
    public let target: Layout
    public let startedAt: UInt64
    public let completedAt: UInt64
}

/// Только внутренний контракт принятия очереди. Настоящий production transport ещё не подключён.
@MainActor
protocol ConversionRecoveryAdapter: AnyObject {
    var isCaptureValid: Bool { get }
    var isOrdinaryRouteCurrent: Bool { get }
    /// Начинается лишь после регистрации Session у внешнего app-owner.
    func activateCapture() -> Bool
    func beginMutation() -> Bool
    func drainPendingInput() async
    /// Закрывает capture и подготавливает маршрут без передачи владения или post.
    func prepareOrdinary() -> Bool
    /// Отказ допустим только ДО claim. После claim transport обязан принять очередь ровно один раз.
    func commitOrdinary(
        correction: ConversionRecoveryLayoutTransition?, claimOwnership: () -> ConversionSafetyInputClaim?
    ) -> Bool
    /// nil claim означает сохранение прежнего владельца, а не выдуманный recovery claim после ordinary decision.
    func retainForRecovery(claim: ConversionSafetyInputClaim?)
}

struct ConversionRecoveryPreparation {
    let session: UUID
    let decision: ConversionSafetyDecision
}

enum ConversionRecoveryCompletion { case ordinaryTransferred, retained, alreadyFinalized }
