import Foundation

struct UnicodeReceiverTarget: Equatable {
    let identity: UUID
    let processID: pid_t
}

enum UnicodeReceiverObservation { case selectionSettled, textConfirmed, cleanupSettled }
enum UnicodeReceiverEvidence { case unresolved, receiverCompleted, preventedBeforeAdmission }

/// Production binding отсутствует: snapshot/post не доказывают завершение конкретного token.
@MainActor
struct UnicodeReceiverContract {
    var bind: (UnicodeReceiverTarget, ConversionSafetyOperationToken) -> UnicodeBoundReceiverContract?
}

@MainActor
struct UnicodeBoundReceiverContract {
    let target: UnicodeReceiverTarget
    let operation: ConversionSafetyOperationToken
    var isCurrent: () -> Bool
    /// Только реальный Up debt исходному экземпляру процесса; не разрешение нового Down.
    var canBalance: () -> Bool
    var completion: (ConversionDispatchReply, UnicodeReceiverObservation) -> UnicodeReceiverEvidence

    func evidence(for reply: ConversionDispatchReply, observation: UnicodeReceiverObservation)
        -> UnicodeReceiverEvidence {
        guard reply.submission.operation == operation, canBalance() else { return .unresolved }
        let result = completion(reply, observation)
        return canBalance() ? result : .unresolved
    }
}
