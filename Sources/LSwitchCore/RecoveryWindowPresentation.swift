import Foundation

/// Только состояние представления. verifiedBlocking обязан поступать от принятого системного gate.
public enum RecoveryWindowProtection: Equatable, Sendable {
    case verifiedBlocking, unverified, unavailable, off
}

public enum RecoveryWindowReason: Equatable, Sendable {
    case cleanupUnconfirmed, admissionStopped, gateLost, interceptionStopped, ordinaryDeliveryUnconfirmed
}

public struct RecoveryWindowCounts: Equatable, Sendable {
    public let events: Int
    public let utf16Bytes: Int

    public init(events: Int, utf16Bytes: Int) {
        self.events = events
        self.utf16Bytes = utf16Bytes
    }
}

/// Метаданные не содержат payload событий и не дают разрешения replay.
public struct RecoveryWindowMetadata: Equatable, Sendable {
    public let recordIdentifier: UUID
    public let applicationName: String
    public let counts: RecoveryWindowCounts
    public let reason: RecoveryWindowReason
    public let protection: RecoveryWindowProtection
    public let ordinaryDelivery: OrdinaryDeliveryProgress?

    public init(
        recordIdentifier: UUID, applicationName: String, counts: RecoveryWindowCounts,
        reason: RecoveryWindowReason, protection: RecoveryWindowProtection,
        ordinaryDelivery: OrdinaryDeliveryProgress? = nil
    ) {
        self.recordIdentifier = recordIdentifier
        self.applicationName = applicationName
        self.counts = counts
        self.reason = reason
        self.protection = protection
        self.ordinaryDelivery = ordinaryDelivery
    }
}

public enum RecoveryWindowNotice: Equatable, Sendable { case revealUnavailable, deletionRefused, deleted }

public struct RecoveryWindowSnapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let metadata: RecoveryWindowMetadata?
    public let isVisible: Bool
    public let isDeleted: Bool
    public let projection: RecoveryProjection?
    public let notice: RecoveryWindowNotice?

    public var description: String { "RecoveryWindowSnapshot(<redacted>)" }
    public var debugDescription: String { description }
}

/// Замыкания адаптера уже связаны с внутренним intent coordinator; повторное решение не исполняется.
@MainActor
public final class RecoveryWindowDeletionRequest {
    public let recordIdentifier: UUID
    private let confirmation: () -> Bool
    private let cancellation: () -> Void
    private var resolved = false

    public init(recordIdentifier: UUID, confirm: @escaping () -> Bool, cancel: @escaping () -> Void) {
        self.recordIdentifier = recordIdentifier
        confirmation = confirm
        cancellation = cancel
    }

    func confirm() -> Bool {
        guard !resolved else { return false }
        resolved = true
        return confirmation()
    }

    func cancel() {
        guard !resolved else { return }
        resolved = true
        cancellation()
    }
}

/// Мост к владельцу RAM. Здесь нет raw events, системных API, clipboard или разрешения отправки.
@MainActor
public struct RecoveryWindowActions {
    let reveal: (UUID) -> RecoveryProjection?
    let requestDeletion: (UUID) -> RecoveryWindowDeletionRequest?
    let didHide: (UUID) -> Void

    public init(
        reveal: @escaping (UUID) -> RecoveryProjection?,
        requestDeletion: @escaping (UUID) -> RecoveryWindowDeletionRequest?,
        didHide: @escaping (UUID) -> Void
    ) {
        self.reveal = reveal
        self.requestDeletion = requestDeletion
        self.didHide = didHide
    }
}

public struct RecoveryWindowDeletionIntent: Equatable, Sendable {
    let session: UUID
    let record: UUID
    let nonce = UUID()
}

public enum RecoveryWindowDeletionResult: Equatable, Sendable { case deleted, cancelled, refused, stale }

public struct RecoveryWindowEditorToken: Equatable, Sendable {
    let session: UUID
    let record: UUID
    let revision: UUID
    let ordinal: Int
    let nonce = UUID()
}

/// Отдельная редактируемая копия одного фрагмента, а не восстановленный текст редактора.
public struct RecoveryWindowDraft: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let token: RecoveryWindowEditorToken
    public let text: String

    public var description: String { "RecoveryWindowDraft(<redacted>)" }
    public var debugDescription: String { description }
}
