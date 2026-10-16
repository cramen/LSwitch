import Foundation

/// Удерживается приложением независимо от Converter. Pending запись нельзя вытеснить новым Converter.
@MainActor
public final class ConversionRecoveryOwner {
    private var admission: ConversionRecoveryAdmission?
    private var heldSession: ConversionRecoverySession?

    public init() {}

    public var hasPendingRecovery: Bool { heldSession?.requiresRecovery == true }
    public var pendingSession: ConversionRecoverySession? { hasPendingRecovery ? heldSession : nil }
    var isOccupied: Bool { admission != nil }

    func reserve() -> ConversionRecoveryAdmission? {
        guard admission == nil else { return nil }
        let reserved = ConversionRecoveryAdmission(owner: self)
        admission = reserved
        return reserved
    }

    func register(_ session: ConversionRecoverySession, admission expected: ConversionRecoveryAdmission) -> Bool {
        guard admission === expected, heldSession == nil else { return false }
        heldSession = session
        return true
    }

    func session(for expected: ConversionRecoveryAdmission) -> ConversionRecoverySession? {
        admission === expected ? heldSession : nil
    }

    func finishInvocation(_ expected: ConversionRecoveryAdmission) {
        guard admission === expected else { return }
        guard heldSession == nil || heldSession?.ordinaryTransferred == true else { return }
        heldSession = nil
        admission = nil
    }
}

/// Weak обратная связь не создаёт недоступный UI self-cycle.
@MainActor
final class ConversionRecoveryAdmission {
    let identifier = UUID()
    private weak var owner: ConversionRecoveryOwner?

    init(owner: ConversionRecoveryOwner) { self.owner = owner }

    func register(_ session: ConversionRecoverySession) -> Bool {
        owner?.register(session, admission: self) == true
    }
}
