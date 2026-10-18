import Foundation

/// Контекст одной замены. Хвост входит в выделяемый фрагмент, но не конвертируется.
public struct ConversionRequest: Sendable {
    public let expectedWord: String?
    public let trailingText: String
    public let replacement: String?
    public let sourceLayout: Layout?
    public let useSelection: Bool
    public let diagnostics: ConversionDiagnostics?
    /// Общий журнал операции не должен теряться при добавлении проверок контекста.
    public let safetyLedger: ConversionSafetyLedger?
    public let beginMutation: @MainActor @Sendable () -> Bool
    public let canCleanup: @MainActor @Sendable () -> Bool
    public let isValid: @MainActor @Sendable () -> Bool
    private(set) var profileValidation: AXProfileRequestValidation?

    public init(
        expectedWord: String? = nil,
        trailingText: String = "",
        replacement: String? = nil,
        sourceLayout: Layout? = nil,
        useSelection: Bool = true,
        diagnostics: ConversionDiagnostics? = nil,
        safetyLedger: ConversionSafetyLedger? = nil,
        beginMutation: @escaping @MainActor @Sendable () -> Bool = { true },
        canCleanup: (@MainActor @Sendable () -> Bool)? = nil,
        isValid: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
        self.expectedWord = expectedWord
        self.trailingText = trailingText
        self.replacement = replacement
        self.sourceLayout = sourceLayout
        self.useSelection = useSelection
        self.diagnostics = diagnostics
        self.safetyLedger = safetyLedger
        self.beginMutation = beginMutation
        self.canCleanup = canCleanup ?? isValid
        self.isValid = isValid
    }

    /// Только этот initializer строит canonical closures; public init и guard wrappers не получают provenance.
    @MainActor
    init(canonical input: CanonicalConversionRequestInput, session: ConversionRecoverySession) {
        self.init(expectedWord: input.expectedWord, trailingText: input.trailingText, replacement: input.replacement,
                  sourceLayout: input.sourceLayout, useSelection: input.useSelection, diagnostics: input.diagnostics,
                  safetyLedger: session.ledger,
                  beginMutation: { [weak session] in session?.beginMutation() == true },
                  canCleanup: { [weak session] in session?.canCleanup == true },
                  isValid: { [weak session] in session?.isValid == true })
        if input.replacement == nil {
            profileValidation = session.makeProfileValidation()
        } else if let anchor = input.undoAnchor, anchor.matches(input) {
            profileValidation = session.makeProfileValidation(undoAnchor: anchor)
        }
    }

    public var expectedSpan: String? {
        expectedWord.map { $0 + trailingText }
    }

    public func converted(_ original: String) -> String {
        if let replacement { return replacement }
        if useSelection {
            if let inferred = textLayout(original) {
                return LayoutMap.shared.convert(original, from: inferred, to: inferred.opposite)
            }
            // Смешанное выделение сохраняет посимвольное поведение ручного хоткея.
            return String(original.map { character in
                if character.isLetter || sourceLayout == nil {
                    return LayoutMap.shared.invert(String(character))
                }
                guard let sourceLayout else { return String(character) }
                return LayoutMap.shared.convert(String(character), from: sourceLayout, to: sourceLayout.opposite)
            }.joined())
        }
        if let sourceLayout {
            return LayoutMap.shared.convert(original, from: sourceLayout, to: sourceLayout.opposite)
        }
        return LayoutMap.shared.invert(original)
    }

    public func targetLayout(for original: String) -> Layout? {
        if useSelection, let inferred = textLayout(original) { return inferred.opposite }
        return sourceLayout?.opposite
    }

    private func textLayout(_ text: String) -> Layout? {
        let layouts = Set(text.filter(\.isLetter).compactMap { LayoutMap.shared.layout(of: $0) })
        return layouts.count == 1 ? layouts.first : nil
    }

    /// Нормализуется только представление пробела в хвосте HTML-редактора.
    public func matchingParts(in text: String) -> (word: String, tail: String)? {
        guard let expectedWord else { return (text, "") }
        guard text.hasPrefix(expectedWord) else { return nil }
        let tail = String(text.dropFirst(expectedWord.count))
        guard Self.normalizedTail(tail) == Self.normalizedTail(trailingText) else { return nil }
        return (expectedWord, tail)
    }

    private static func normalizedTail(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00a0}", with: " ")
    }
}

/// Подтверждённая замена; original используется для точного отката.
public struct ConversionReceipt: Equatable, Sendable {
    public typealias TargetCheck = @MainActor @Sendable () -> Bool
    public let original: String
    public let converted: String
    public let trailingText: String
    public let targetIsCurrent: TargetCheck?
    let profileTarget: AXProfileReceiptTarget?

    public init(
        original: String, converted: String, trailingText: String = "", targetIsCurrent: TargetCheck? = nil
    ) {
        self.original = original
        self.converted = converted
        self.trailingText = trailingText
        self.targetIsCurrent = targetIsCurrent
        profileTarget = nil
    }

    init(original: String, converted: String, trailingText: String, profileTarget: AXProfileReceiptTarget) {
        self.original = original
        self.converted = converted
        self.trailingText = trailingText
        self.profileTarget = profileTarget
        targetIsCurrent = { profileTarget.isCurrent }
    }

    /// Guard — runtime-контекст, а не часть значения сохранённого текста.
    public static func == (lhs: ConversionReceipt, rhs: ConversionReceipt) -> Bool {
        lhs.original == rhs.original && lhs.converted == rhs.converted && lhs.trailingText == rhs.trailingText
    }
}

public enum ConversionResult: Equatable, Sendable {
    case success(ConversionReceipt)
    /// Текст не изменён, исходное выделение восстановлено; можно пробовать другой движок.
    case unavailable
    /// Защищённое поле или устаревший контекст; повторные пути запрещены.
    case blocked
    /// Запись могла произойти; повторный путь может повредить текст.
    case failed
}

@MainActor
public protocol ConversionEngine {
    func perform(_ request: ConversionRequest) async -> ConversionResult
}
