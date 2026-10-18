#if DEBUG
import Foundation

/// Только внутренний системный boundary; fake используется без native start/post в компонентных тестах.
protocol TextEditRecoveryDriver: AnyObject, Sendable {
    var bridge: RecoveryRecipientProbeBridge { get }
    var permitsCaptureReservation: Bool { get }
    var permitsMutation: Bool { get }
    var isProtectionAvailable: Bool { get }
    func start() async -> Bool
    func stop() async -> Bool
    func withProtection(_ body: () -> Void)
    @MainActor func refreshProtection() -> Bool
    @MainActor func armRecipientCapture(
        _ capture: RecipientOrdinaryCapture, processingArm: PreparedEventProcessingArm?
    ) async -> Bool
    @MainActor func prepareOrdinaryFlush(
        capture: RecipientOrdinaryCapture, deadline: UInt64, diagnosticMarker: Int64?
    ) -> RecipientOrdinaryFlush?
    @MainActor func acceptOrdinary(
        _ flush: RecipientOrdinaryFlush, correction: ConversionRecoveryLayoutTransition?,
        claimOwnership: () -> ConversionSafetyInputClaim?
    ) -> ConversionOrdinaryAcceptance
}

extension RecipientTapDriver: TextEditRecoveryDriver {
    @MainActor
    func acceptOrdinary(
        _ flush: RecipientOrdinaryFlush, correction: ConversionRecoveryLayoutTransition?,
        claimOwnership: () -> ConversionSafetyInputClaim?
    ) -> ConversionOrdinaryAcceptance {
        flush.accept(correction: correction, claimOwnership: claimOwnership)
    }
}

/// Снимки остаются во внутреннем state; callbacks здесь выполняются только на MainActor вне native locks.
@MainActor
struct TextEditRecoveryLogicalLease {
    let prepared: PreparedEventProcessingArm
    let isCurrent: () -> Bool
    let drain: () async -> Void
    let finish: (EventProcessingDisposition, EventProcessingActions) async -> EventProcessingFinish
}

@MainActor
struct TextEditRecoveryAdapterResources {
    let ledger: ConversionSafetyLedger
    let coordinator: RecoveryCoordinator
    let driver: any TextEditRecoveryDriver
    let operation: RecoveryOperation
    let capture: RecipientOrdinaryCapture
    let logical: TextEditRecoveryLogicalLease
}
#endif
