import Foundation

/// Конкретный stored-state fence. Здесь нет пользовательского closure, AX или обращения к foreground.
@MainActor
final class ConverterRevisionFence {
    private weak var converter: Converter?
    private let generation: UInt64

    init(converter: Converter, generation: UInt64) { self.converter = converter; self.generation = generation }
    var isCurrent: Bool { converter?.revision == generation }
}

/// Поля ticket недоступны потребителю профиля; nonce остаётся однократным в Session.
struct AXProfileValidationToken {
    private let session: UUID
    private let nonce: UUID

    init(session: UUID, nonce: UUID) { self.session = session; self.nonce = nonce }
    func matches(session: UUID, nonce: UUID?) -> Bool { self.session == session && self.nonce == nonce }
}

/// Capability не удерживает Session и не разрешает fallback после исчезновения владельца.
@MainActor
final class AXProfileRequestValidation {
    let binding: ConversionSafetyProfileBinding
    let operation: ConversionSafetyOperationToken
    let undoTarget: AXProfileReceiptTarget?
    let undoSpan: String?
    private weak var session: ConversionRecoverySession?

    init(
        session: ConversionRecoverySession, binding: ConversionSafetyProfileBinding,
        undoAnchor: ConversionUndoProfileAnchor? = nil
    ) {
        self.session = session
        self.binding = binding
        operation = session.ledger.operation
        undoTarget = undoAnchor?.target
        undoSpan = undoAnchor?.span
    }

    func matches(ledger: ConversionSafetyLedger) -> Bool {
        session?.ledger === ledger && ledger.operation == operation && ledger.profileBinding == binding
    }

    func begin(
        binding: ConversionSafetyProfileBinding, operation: ConversionSafetyOperationToken
    ) -> AXProfileValidationToken? {
        guard binding == self.binding, operation == self.operation else { return nil }
        return session?.beginProfileValidation(binding: binding)
    }

    func finish(_ token: AXProfileValidationToken) -> Bool { session?.finishProfileValidation(token) == true }
}

struct CanonicalConversionRequestInput {
    let expectedWord: String?
    let trailingText: String
    let replacement: String?
    let sourceLayout: Layout?
    let useSelection: Bool
    let diagnostics: ConversionDiagnostics
    var undoAnchor: ConversionUndoProfileAnchor? = nil
}
