import Foundation

/// Доказано только содержимое Unicode payload события, не вставка или конечный текст редактора.
public enum RecoveryFragmentEvidence: Equatable, Sendable { case eventPayloadOnly }

public enum RecoveryProjectionFailure: Equatable, Sendable {
    case eventLimitExceeded, payloadLimitExceeded
}

public enum RecoveryProjectionIssue: Equatable, Sendable {
    case missingUnicodePayload, invalidUTF16, unicodeReadInconsistent, controlUnicodePayload
    case modifierDependentInput, unsupportedModifiers, unsupportedEvent
}

/// Названия физических управляющих клавиш не обещают выполнение стандартной команды редактора.
public enum RecoveryEditingKey: Equatable, Sendable {
    case backspace, forwardDelete, enter, tab, escape, navigation, function
}

public enum RecoveryMouseButton: Equatable, Sendable { case left, right, other }
public enum RecoveryMousePhase: Equatable, Sendable { case down, up, drag }

public enum RecoveryNonTextEvent: Equatable, Sendable {
    case keyRelease, modifierChange, modifiedKey
    case editingKey(RecoveryEditingKey)
    case mouse(button: RecoveryMouseButton, phase: RecoveryMousePhase)
}

/// Доступен только в результате явного раскрытия. Не нормализует исходные UTF-16 units.
public struct RecoveryUnicodeFragment: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let text: String
    public let evidence: RecoveryFragmentEvidence

    init(text: String) {
        self.text = text
        evidence = .eventPayloadOnly
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.evidence == rhs.evidence && lhs.text.utf16.elementsEqual(rhs.text.utf16)
    }

    public var description: String { "RecoveryUnicodeFragment(<redacted>, eventPayloadOnly)" }
    public var debugDescription: String { description }
}

public enum RecoveryProjectionContent: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case unicodeFragment(RecoveryUnicodeFragment)
    case nonText(RecoveryNonTextEvent)
    case unresolved(RecoveryProjectionIssue)

    public var description: String {
        switch self {
        case .unicodeFragment: return "RecoveryProjectionContent.unicodeFragment(<redacted>)"
        case .nonText: return "RecoveryProjectionContent.nonText"
        case .unresolved: return "RecoveryProjectionContent.unresolved"
        }
    }

    public var debugDescription: String { description }
}

public struct RecoveryProjectionEntry: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Индекс в исходной очереди, начиная с нуля. Отпускания и команды не удаляются из порядка.
    public let ordinal: Int
    public let content: RecoveryProjectionContent

    public var description: String { "RecoveryProjectionEntry(ordinal: \(ordinal), <redacted>)" }
    public var debugDescription: String { description }
}

/// Поэлементная проекция. У неё намеренно нет вычисленной общей или конечной строки.
public struct RecoveryProjection: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let recordIdentifier: UUID
    public let entries: [RecoveryProjectionEntry]
    /// Явный отказ бюджета возвращает пустой entries, а не молчаливо усечённый префикс.
    public let failure: RecoveryProjectionFailure?

    public var description: String { "RecoveryProjection(entries: \(entries.count), <redacted>)" }
    public var debugDescription: String { description }
}

/// Чистая граница строгого декодирования; не читает CGEvent и не восстанавливает семантику ввода.
enum RecoveryUnicodeProjection {
    static func content(
        units: [UInt16], expectedCount: Int, actualCount: Int, recheckedCount: Int
    ) -> RecoveryProjectionContent {
        guard expectedCount >= 0, expectedCount == actualCount, expectedCount == recheckedCount,
              expectedCount == units.count else { return .unresolved(.unicodeReadInconsistent) }
        guard !units.isEmpty else { return .unresolved(.missingUnicodePayload) }
        guard hasValidSurrogates(units) else { return .unresolved(.invalidUTF16) }
        // Управляющие значения и AppKit function-key Unicode не выдаём за обычный текст.
        guard !units.contains(where: isControl) else { return .unresolved(.controlUnicodePayload) }
        let text = String(decoding: units, as: UTF16.self)
        guard text.utf16.elementsEqual(units) else { return .unresolved(.invalidUTF16) }
        return .unicodeFragment(RecoveryUnicodeFragment(text: text))
    }

    private static func isControl(_ unit: UInt16) -> Bool {
        unit < 0x20 || (0x7F...0x9F).contains(unit) || (0xF700...0xF8FF).contains(unit)
    }

    private static func hasValidSurrogates(_ units: [UInt16]) -> Bool {
        var index = 0
        while index < units.count {
            let unit = units[index]
            if (0xD800...0xDBFF).contains(unit) {
                guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else { return false }
                index += 2
            } else {
                guard !(0xDC00...0xDFFF).contains(unit) else { return false }
                index += 1
            }
        }
        return true
    }
}
