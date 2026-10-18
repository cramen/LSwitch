#if DEBUG
import Foundation

enum RecoveryDiagnosticPacketKind: Equatable { case down, release }

struct RecoveryDiagnosticPairResult {
    let downAttempted: Bool
    let releaseAttempted: Bool
    let balancingRelease: Bool
    let completed: Bool
    var unpostedDebt: Bool { downAttempted && !releaseAttempted }
    var inconclusive: Bool { downAttempted && !completed }
}

/// Подготовка пары не отправляет первый пакет при отсутствии второго. Один plan используется один раз.
@MainActor
final class RecoveryDiagnosticPair<Packet> {
    struct Actions {
        let canSubmit: (RecoveryDiagnosticPacketKind, Packet) -> Bool
        let canBalance: (Packet) -> Bool
        let post: (RecoveryDiagnosticPacketKind, Packet) -> Void
    }

    private let down: Packet
    private let release: Packet
    private var used = false

    private init(down: Packet, release: Packet) { self.down = down; self.release = release }

    static func prepare(_ make: (RecoveryDiagnosticPacketKind) -> Packet?) -> RecoveryDiagnosticPair? {
        guard let down = make(.down), let release = make(.release) else { return nil }
        return .init(down: down, release: release)
    }

    func dispatch(_ actions: Actions) -> RecoveryDiagnosticPairResult? {
        guard !used else { return nil }
        used = true
        let progress = RecoveryDiagnosticPairProgress()
        attempt(actions, progress: progress)
        return progress.result
    }

    private func attempt(_ actions: Actions, progress: RecoveryDiagnosticPairProgress) {
        defer {
            if progress.downAttempted, !progress.releaseAttempted, actions.canBalance(release) {
                progress.releaseAttempted = true
                progress.balancingRelease = true
                actions.post(.release, release)
            }
        }
        guard actions.canSubmit(.down, down) else { return }
        progress.downAttempted = true
        actions.post(.down, down)
        guard actions.canSubmit(.release, release) else { return }
        progress.releaseAttempted = true
        actions.post(.release, release)
        progress.completed = true
    }
}

private final class RecoveryDiagnosticPairProgress {
    var downAttempted = false
    var releaseAttempted = false
    var balancingRelease = false
    var completed = false

    var result: RecoveryDiagnosticPairResult {
        .init(downAttempted: downAttempted, releaseAttempted: releaseAttempted,
              balancingRelease: balancingRelease, completed: completed)
    }
}
#endif
