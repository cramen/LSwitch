import ApplicationServices

/// Этап наблюдения не является receiver ACK. Его интерпретирует отдельно принятый контракт получателя.
enum AXWriteObservation { case selectedRangeSettled, replacementObserved, finalStateSettled, cleanupSettled }
enum AXCompletionEvidence { case unresolved, receiverCompleted }

@MainActor
struct AXReceiverContract {
    let bind: (AXUIElement, ConversionSafetyOperationToken) -> AXBoundReceiverContract?
}

/// Одноразовая операция связана с конкретным элементом; default production factory пока отсутствует.
@MainActor
final class AXBoundReceiverContract {
    private let element: AXUIElement
    private let operation: ConversionSafetyOperationToken
    private let valid: () -> Bool
    private let completion: (AXWriteReply, AXWriteObservation) -> AXCompletionEvidence

    init(
        element: AXUIElement, operation: ConversionSafetyOperationToken,
        isValid: @escaping () -> Bool,
        completion: @escaping (AXWriteReply, AXWriteObservation) -> AXCompletionEvidence
    ) {
        self.element = element
        self.operation = operation
        self.valid = isValid
        self.completion = completion
    }

    func isValid(for target: AXUIElement, operation token: ConversionSafetyOperationToken) -> Bool {
        token == operation && CFEqual(element, target) && valid()
    }

    func evidence(for reply: AXWriteReply, observation: AXWriteObservation) -> AXCompletionEvidence {
        guard reply.submission.operation == operation, valid() else { return .unresolved }
        let evidence = completion(reply, observation)
        return valid() ? evidence : .unresolved
    }
}
