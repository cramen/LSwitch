import ApplicationServices
import Foundation
import os

/// Границы последнего слова в строке — чистая логика AX-конвертера,
/// вынесенная для unit-тестов.
public enum WordBoundary {

    /// Символ слова: буква любого алфавита ИЛИ символ с соответствием
    /// в раскладке («;» — это «ж», «'» — «э»): на экране может оказаться
    /// текст, набранный в неправильной раскладке. Хвостовая пунктуация
    /// после извлечения обрезается (см. lastWord).
    public static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || LayoutMap.shared.layout(of: character) != nil
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
        // Хвостовая пунктуация («привет,») не входит в слово, внутренняя
        // раскладочная («rf;tncz») — входит.
        while end > start {
            let last = text[text.index(before: end)]
            guard !last.isLetter else { break }
            end = text.index(before: end)
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

/// Замена через Accessibility с проверкой текста, фокуса и конечной каретки.
@MainActor
public final class AXTextConverter: ConversionEngine {

    public struct Outcome: Equatable {
        public let original: String
        public let converted: String
        public let wasSelection: Bool
    }

    private let access: any AXTextAccess
    private let transform: (String) -> String
    private let logger = Logger(subsystem: "LSwitch", category: "AXConverter")

    public convenience init(transform: @escaping (String) -> String = { LayoutMap.shared.invert($0) }) {
        self.init(access: SystemAXTextAccess(), transform: transform)
    }

    init(
        access: any AXTextAccess,
        transform: @escaping (String) -> String = { LayoutMap.shared.invert($0) }
    ) {
        self.access = access
        self.transform = transform
    }

    public static func isSecureField(_ element: AXUIElement) -> Bool {
        SystemAXTextAccess.isSecureField(element)
    }

    public func focusedElement() -> AXUIElement? {
        access.focusedElement()
    }

    public func perform(_ request: ConversionRequest) -> ConversionResult {
        execute(request, transform: request.converted).result
    }

    /// Обёртка для диагностического режима; основной путь использует явный запрос.
    public func convert() -> Result<Outcome, AXConvertError> {
        let execution = execute(ConversionRequest(), transform: transform)
        switch execution.result {
        case .success(let receipt):
            return .success(Outcome(
                original: receipt.original,
                converted: receipt.converted,
                wasSelection: execution.wasSelection
            ))
        case .blocked:
            return .failure(.secureField)
        case .unavailable:
            return .failure(.textUnavailable)
        case .failed:
            return .failure(.writeFailed)
        }
    }

    private func execute(
        _ request: ConversionRequest,
        transform: (String) -> String
    ) -> (result: ConversionResult, wasSelection: Bool) {
        guard request.isValid(), let element = access.focusedElement(),
              !access.isProtected(element) else {
            return (logged(.blocked, reason: "protected-or-invalid-context"), false)
        }
        guard let text = access.text(in: element), let selection = access.selection(in: element),
              let plan = AXReplacementPlan(text: text, selection: selection, request: request, transform: transform)
        else { return (logged(.unavailable, reason: "snapshot-or-plan-unavailable"), false) }
        guard access.canReplaceText(in: element), access.canSetSelection(in: element) else {
            return (logged(.unavailable, reason: "attributes-not-settable"), plan.wasSelection)
        }
        let result = replace(plan, in: element, request: request)
        if !request.isValid() { cleanupAfterAbort(plan, in: element, request: request) }
        return (result, plan.wasSelection)
    }

    private func cleanupAfterAbort(_ plan: AXReplacementPlan, in element: AXUIElement, request: ConversionRequest) {
        guard request.canCleanup(), let focused = access.focusedElement(), CFEqual(focused, element),
              !access.isProtected(element), let text = access.text(in: element),
              let selection = access.selection(in: element), request.canCleanup() else { return }
        if text == plan.text && selection == plan.range && !plan.wasSelection {
            _ = access.setSelection(plan.selection, in: element)
        } else if text == plan.resultingText,
                  selection == NSRange(location: plan.range.location, length: plan.replacement.utf16.count) {
            _ = access.setSelection(plan.finalSelection, in: element)
        }
    }

    private func replace(
        _ plan: AXReplacementPlan,
        in element: AXUIElement,
        request: ConversionRequest
    ) -> ConversionResult {
        guard isCurrent(element, request: request),
              access.text(in: element) == plan.text,
              access.selection(in: element) == plan.selection else {
            return logged(.blocked, reason: "snapshot-changed-before-selection")
        }
        guard request.beginMutation(), isCurrent(element, request: request) else {
            return logged(.blocked, reason: "input-hold-unavailable")
        }
        if plan.range != plan.selection {
            guard access.setSelection(plan.range, in: element) else {
                let result = restoreSelection(plan, in: element, request: request)
                return logged(result, reason: "selection-write-failed")
            }
        }
        guard isCurrent(element, request: request), access.text(in: element) == plan.text else {
            return logged(.blocked, reason: "context-changed-after-selection")
        }
        guard access.selection(in: element) == plan.range else {
            let result = restoreSelection(plan, in: element, request: request)
            return logged(result, reason: "selection-not-confirmed")
        }
        let written = access.replaceSelectedText(plan.replacement, in: element)
        guard written else {
            _ = recoverAfterWrite(plan, in: element, request: request)
            return logged(.failed, reason: "text-write-failed")
        }
        return finishWrite(plan, in: element, request: request)
    }

    private func finishWrite(
        _ plan: AXReplacementPlan,
        in element: AXUIElement,
        request: ConversionRequest
    ) -> ConversionResult {
        guard isCurrent(element, request: request) else {
            return logged(.failed, reason: "context-changed-after-write")
        }
        guard access.text(in: element) == plan.resultingText else {
            let result = recoverAfterWrite(plan, in: element, request: request)
            return logged(result, reason: "text-write-not-confirmed")
        }
        guard access.setSelection(plan.finalSelection, in: element) else {
            return logged(.failed, reason: "final-caret-write-failed")
        }
        guard isCurrent(element, request: request),
              access.text(in: element) == plan.resultingText,
              access.selection(in: element) == plan.finalSelection else {
            return logged(.failed, reason: "final-state-not-confirmed")
        }
        return logged(.success(plan.receipt), reason: "replacement-confirmed")
    }

    /// «Успешный» AX no-op разрешает fallback лишь после полного восстановления снимка.
    private func recoverAfterWrite(
        _ plan: AXReplacementPlan,
        in element: AXUIElement,
        request: ConversionRequest
    ) -> ConversionResult {
        guard isCurrent(element, request: request), let text = access.text(in: element) else { return .failed }
        if text == plan.text {
            return restoreSelection(plan, in: element, request: request)
        }
        // При иной записи текст не трогаем. Снимаем только узнаваемое собственное выделение.
        guard let selection = access.selection(in: element),
              let caret = plan.cleanupCaret(in: text, selection: selection),
              isCurrent(element, request: request), access.text(in: element) == text,
              access.selection(in: element) == selection else { return .failed }
        let collapsed = access.setSelection(caret, in: element)
        let verified = collapsed && access.selection(in: element) == caret
        logger.info("AX cleanup изменённого текста: каретка подтверждена=\(verified, privacy: .public)")
        return .failed
    }

    private func isCurrent(_ element: AXUIElement, request: ConversionRequest) -> Bool {
        guard request.isValid(), let focused = access.focusedElement(), CFEqual(focused, element) else {
            return false
        }
        return !access.isProtected(element)
    }

    /// Fallback допустим только после подтверждения неизменного текста и исходного выделения.
    private func restoreSelection(
        _ plan: AXReplacementPlan,
        in element: AXUIElement,
        request: ConversionRequest
    ) -> ConversionResult {
        guard isCurrent(element, request: request), access.text(in: element) == plan.text else { return .blocked }
        if access.selection(in: element) != plan.selection {
            guard access.setSelection(plan.selection, in: element) else { return .failed }
        }
        guard isCurrent(element, request: request), access.text(in: element) == plan.text,
              access.selection(in: element) == plan.selection else { return .failed }
        return .unavailable
    }

    private func logged(_ result: ConversionResult, reason: String) -> ConversionResult {
        let label: String
        switch result {
        case .success: label = "success"
        case .unavailable: label = "unavailable"
        case .blocked: label = "blocked"
        case .failed: label = "failed"
        }
        logger.info("AX результат=\(label, privacy: .public), причина=\(reason, privacy: .public)")
        return result
    }
}
