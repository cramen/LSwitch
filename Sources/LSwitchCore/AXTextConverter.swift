import ApplicationServices
import Foundation

/// Границы последнего слова в строке — чистая логика AX-конвертера,
/// вынесенная для unit-тестов.
public enum WordBoundary {

    /// Символ слова: буква любого алфавита. Цифры и пунктуация — разделители
    /// (согласуется с эвристикой F11: пароль-подобные строки не конвертируем).
    public static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter
    }

    /// Последнее слово перед позицией курсора.
    ///
    /// Курсор может стоять сразу после разделителя («слово |») — сначала
    /// отступаем за разделители, затем берём непрерывный ряд букв.
    /// - Returns: диапазон слова или `nil`, если слова перед курсором нет.
    public static func lastWord(in text: String, beforeCursor cursor: String.Index) -> Range<String.Index>? {
        var end = cursor
        while end > text.startIndex {
            let previous = text[text.index(before: end)]
            if isWordCharacter(previous) { break }
            end = text.index(before: end)
        }
        var start = end
        while start > text.startIndex {
            let previous = text[text.index(before: start)]
            guard isWordCharacter(previous) else { break }
            start = text.index(before: start)
        }
        guard start < end else { return nil }
        return start..<end
    }
}

/// Ошибки AX-режима конвертации.
public enum AXConvertError: Error, Equatable {
    /// Нет сфокусированного элемента (или нет разрешения Accessibility).
    case noFocusedElement
    /// Фокус в secure-поле (пароль) — конвертация запрещена (spec: F8).
    case secureField
    /// Элемент не отдал ни выделенный текст, ни значение с диапазоном.
    case textUnavailable
    /// Перед курсором нет слова для конвертации.
    case emptyWord
    /// Запись обратно в элемент не удалась.
    case writeFailed
}

/// Конвертация текста через Accessibility API без буфера обмена (спайк P0.2).
///
/// Порядок попыток (design D4):
/// 1. `AXSelectedText` — если есть выделение, конвертируем его.
/// 2. `AXValue` + `AXSelectedTextRange` — вычисляем границы последнего слова,
///    выделяем его и заменяем через запись `AXSelectedText`.
public final class AXTextConverter {

    /// Результат успешной конвертации: что и во что превратили (для лога спайка).
    public struct Outcome: Equatable {
        public let original: String
        public let converted: String
        public let wasSelection: Bool
    }

    private let systemWide: AXUIElement
    private let transform: (String) -> String

    public init(transform: @escaping (String) -> String = { LayoutMap.shared.invert($0) }) {
        self.systemWide = AXUIElementCreateSystemWide()
        self.transform = transform
    }

    /// Secure-поле определяется по subrole `AXSecureTextField`.
    public static func isSecureField(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success,
              let subrole = value as? String else { return false }
        return subrole == "AXSecureTextField"
    }

    public func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success, let value else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    /// Выполняет конвертацию выделения либо последнего слова перед курсором.
    public func convert() -> Result<Outcome, AXConvertError> {
        guard let element = focusedElement() else { return .failure(.noFocusedElement) }
        guard !Self.isSecureField(element) else { return .failure(.secureField) }

        if let selected = copyStringAttribute(kAXSelectedTextAttribute, from: element), !selected.isEmpty {
            return replaceSelection(selected, in: element, wasSelection: true)
        }
        return convertLastWordBeforeCursor(in: element)
    }

    // MARK: - Внутренности

    private func convertLastWordBeforeCursor(in element: AXUIElement) -> Result<Outcome, AXConvertError> {
        guard let value = copyStringAttribute(kAXValueAttribute, from: element),
              let selectionRange = copyRangeAttribute(kAXSelectedTextRangeAttribute, from: element),
              let cursorNSRange = Range(selectionRange, in: value) else {
            return .failure(.textUnavailable)
        }
        guard let wordRange = WordBoundary.lastWord(in: value, beforeCursor: cursorNSRange.lowerBound) else {
            return .failure(.emptyWord)
        }
        // AX-позиции отсчитываются в UTF-16 — NSRange даёт их напрямую.
        let wordNSRange = NSRange(wordRange, in: value)
        guard setRangeAttribute(
            kAXSelectedTextRangeAttribute,
            CFRange(location: wordNSRange.location, length: wordNSRange.length),
            on: element
        ) else {
            return .failure(.writeFailed)
        }
        let word = String(value[wordRange])
        return replaceSelection(word, in: element, wasSelection: false)
    }

    private func replaceSelection(
        _ original: String,
        in element: AXUIElement,
        wasSelection: Bool
    ) -> Result<Outcome, AXConvertError> {
        let converted = transform(original)
        let error = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            converted as CFTypeRef
        )
        guard error == .success else { return .failure(.writeFailed) }
        return .success(Outcome(original: original, converted: converted, wasSelection: wasSelection))
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func copyRangeAttribute(_ attribute: String, from element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let axValue = value, CFGetTypeID(axValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func setRangeAttribute(_ attribute: String, _ range: CFRange, on element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let axValue = AXValueCreate(.cfRange, &mutableRange) else { return false }
        return AXUIElementSetAttributeValue(element, attribute as CFString, axValue) == .success
    }
}
