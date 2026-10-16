#if DEBUG
import Foundation

/// Только DEBUG-кандидат. Fast свойства читают RAM; guarded body синхронен и не является renderer ACK.
public protocol RecoveryIsolationProtecting: AnyObject, Sendable {
    var bridge: RecoveryRecipientProbeBridge { get }
    var isProtectionAvailable: Bool { get }
    var permitsMutation: Bool { get }
    @MainActor func refreshProtection() -> Bool
    func withProtection(_ body: () -> Void)
}

public struct RecoveryIsolationFixtureMarkers: Sendable {
    public let prefixDown: Int64
    public let prefixRelease: Int64
    public let challengeDown: Int64
    public let challengeRelease: Int64
}

/// Диагностические метаданные без строк событий, CGEvent, диапазонов или clipboard.
public struct RecoveryIsolationReport: Sendable {
    public let senderProcessID: Int32
    public let targetProcessID: Int32
    public let capturedEvents: Int
    public let capturedUTF16Bytes: Int
    public let rejectedFixtureEvents: Int
    public let payloadCountReads: Int
    public let captureAttached: Bool
    public let captureDetached: Bool
    public let selectionCommandRegistered: Bool
    public let selectionUnknown: Bool
    public let adopted: Bool
    public let retainedBeforeAdoption: Bool
    public let preAdoptLossUnresolved: Bool
    public let storageOnlyAdopted: Bool
    public let retirementPending: Bool
    public let eventsRemaining: Int
    public let utf16BytesRemaining: Int
    public let ledgerSubmissionCount: Int
    public let ledgerHasUnknown: Bool
    public let recoveryRequired: Bool
    public let inputClaimedForRecovery: Bool
    public let payloadDeleted: Bool
    public let revealCount: Int
    public let fixtureOnly = true
    public let replayAuthorized = false
    public let recoveryGateAccepted = false
}

/// Слот существует до reserve. Захват и handover пользуются разными состояниями одного driver.
final class RecoveryIsolationProtectionSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var driver: (any RecoveryIsolationProtecting)?
    private var lost = false

    func bind(_ driver: any RecoveryIsolationProtecting) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.driver == nil, !lost else { return false }
        self.driver = driver
        return true
    }

    func invalidate() {
        lock.lock()
        lost = true
        lock.unlock()
    }

    var permitsMutation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !lost && driver?.permitsMutation == true
    }

    var isProtectionAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !lost && driver?.isProtectionAvailable == true
    }

    func withProtection(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !lost else { return }
        driver?.withProtection(body)
    }
}
#endif
