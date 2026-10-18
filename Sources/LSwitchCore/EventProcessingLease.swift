import Foundation

/// Логическая пауза, не право native post/capture. Подделка одного номера epoch не даёт владения.
struct EventProcessingLease: Equatable, Sendable {
    let scope: RecoveryOperationTarget
    let epoch: UInt64
    fileprivate let stateIdentity: UUID
    fileprivate let nonce: UUID

    init(scope: RecoveryOperationTarget, epoch: UInt64, stateIdentity: UUID) {
        self.scope = scope
        self.epoch = epoch
        self.stateIdentity = stateIdentity
        nonce = UUID()
    }
}

enum EventProcessingInvalidation: Equatable, Sendable {
    case inputBeforeCapture, expired, eventLimit, payloadLimit, invalidPayload
    case focusChanged, stopped, permissionLost, captureRefused
}

enum EventProcessingDisposition: Sendable {
    case delivered(QueuedInputCorrection?)
    case discard
}

enum EventProcessingFinish: Equatable, Sendable {
    case delivered, discarded, reset(EventProcessingInvalidation), stale
}

/// Только синхронные MainActor действия: outcome выполняется один раз перед всем tail.
@MainActor
struct EventProcessingActions {
    let applyOutcome: @MainActor @Sendable () -> Void
    let reset: @MainActor @Sendable () -> Void
    let consume: @MainActor @Sendable (RawKeyEvent) -> Void
    var didFinish: @MainActor @Sendable () -> Void = {}
}

struct EventProcessingMetadata: Equatable, Sendable {
    let activity: UInt64
    let eventCount: Int
    let utf16Bytes: Int
    let payloadReads: Int
    let armed: Bool
    let failure: EventProcessingInvalidation?
}

enum EventProcessingStep {
    case event(RawKeyEvent)
    case finished(EventProcessingFinish)
}
