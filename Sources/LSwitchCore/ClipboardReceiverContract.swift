import Foundation

enum ClipboardReceiverObservation { case commandReturned, selectionSettled, textConfirmed, cleanupSettled }
enum ClipboardReceiverEvidence: Equatable { case unresolved, receiverCompleted, preventedBeforeAdmission }

/// Системная реализация пока отсутствует; тестовый приёмник доказывает каждый token отдельно.
@MainActor
struct ClipboardReceiverContract {
    var bind: (UUID, ConversionSafetyOperationToken) -> ClipboardBoundReceiverContract?
}

@MainActor
struct ClipboardBoundReceiverContract {
    let contextIdentity: UUID
    let operation: ConversionSafetyOperationToken
    var isCurrent: () -> Bool
    /// Балансировать разрешено только уже отправленный Down исходному экземпляру процесса.
    var canBalance: () -> Bool
    var completion: (ClipboardDispatchReply, ClipboardReceiverObservation) -> ClipboardReceiverEvidence
    var nativeBinding: NativeDispatchBinding?

    func evidence(
        for reply: ClipboardDispatchReply, observation: ClipboardReceiverObservation
    ) -> ClipboardReceiverEvidence {
        guard reply.submission.operation == operation, canBalance() else { return .unresolved }
        let evidence = completion(reply, observation)
        return canBalance() ? evidence : .unresolved
    }
}
