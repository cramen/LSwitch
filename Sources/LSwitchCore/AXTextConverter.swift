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

    public func perform(_ request: ConversionRequest) async -> ConversionResult {
        await execute(request, transform: request.converted).result
    }

    /// Обёртка для диагностического режима; основной путь использует явный запрос.
    public func convert() async -> Result<Outcome, AXConvertError> {
        let execution = await execute(ConversionRequest(), transform: transform)
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

    private final class Mutation {
        var attempted = false
    }

    private func execute(
        _ request: ConversionRequest,
        transform: (String) -> String
    ) async -> (result: ConversionResult, wasSelection: Bool) {
        guard request.isValid(), let element = access.focusedElement(),
              !access.isProtected(element) else {
            return (logged(.blocked, reason: "protected-or-invalid-context"), false)
        }
        let context = request.isAutomatic ? access.automaticContext(in: element) : .prose
        let identity = request.isAutomatic ? context.documentIdentity : access.documentIdentity(in: element)
        let targetCheck = ConversionDocumentTarget.check(identity: identity, read: {
            self.access.documentIdentity(in: element)
        })
        let scoped = request.checkingDocumentContext(context, read: { self.access.automaticContext(in: element) })
        let request = request.isAutomatic ? scoped : scoped.checkingTarget(targetCheck)
        guard isCurrent(element, request: request) else { return (.blocked, false) }
        guard let text = access.text(in: element), let selection = access.selection(in: element),
              let plan = AXReplacementPlan(text: text, selection: selection, request: request, transform: transform)
        else { return (logged(.unavailable, reason: "snapshot-or-plan-unavailable"), false) }
        guard request.permitsAutomaticContext(context, plan: plan), isCurrent(element, request: request) else {
            return (logged(.blocked, reason: "automatic-context-not-permitted"), plan.wasSelection)
        }
        guard access.canReplaceText(in: element), access.canSetSelection(in: element) else {
            return (logged(.unavailable, reason: "attributes-not-settable"), plan.wasSelection)
        }
        let mutation = Mutation()
        let result = await replace(plan, in: element, request: request, mutation: mutation)
        if mutation.attempted {
            switch result {
            case .success: break
            default: await cleanup(plan, in: element, request: request)
            }
        }
        if case .success(let receipt) = result {
            return (.success(receipt.checkingTarget(targetCheck)), plan.wasSelection)
        }
        return (result, plan.wasSelection)
    }

    private func replace(
        _ plan: AXReplacementPlan,
        in element: AXUIElement,
        request: ConversionRequest,
        mutation: Mutation
    ) async -> ConversionResult {
        guard isCurrent(element, request: request),
              access.text(in: element) == plan.text,
              access.selection(in: element) == plan.selection else {
            return logged(.blocked, reason: "snapshot-changed-before-selection")
        }
        guard request.beginMutation(), isCurrent(element, request: request) else {
            return logged(.blocked, reason: "input-hold-unavailable")
        }
        if plan.range != plan.selection {
            mutation.attempted = true
            guard access.setSelection(plan.range, in: element) else {
                return logged(.failed, reason: "selection-write-failed")
            }
            let settled = await settle(
                text: plan.text, selection: plan.range, allowed: [plan.selection, plan.range],
                in: element, isValid: { self.isCurrent(element, request: request) }
            )
            guard settled else {
                let result: ConversionResult = isCurrent(element, request: request) ? .failed : .blocked
                return logged(result, reason: "selection-not-settled")
            }
        }
        guard isCurrent(element, request: request), access.text(in: element) == plan.text,
              access.selection(in: element) == plan.range else {
            return logged(.blocked, reason: "context-changed-after-selection")
        }
        mutation.attempted = true
        guard access.replaceSelectedText(plan.replacement, in: element) else {
            return logged(.failed, reason: "text-write-failed")
        }
        return await finishWrite(plan, in: element, request: request)
    }

    private func finishWrite(
        _ plan: AXReplacementPlan,
        in element: AXUIElement,
        request: ConversionRequest
    ) async -> ConversionResult {
        guard isCurrent(element, request: request), access.text(in: element) == plan.resultingText else {
            return logged(.failed, reason: "text-write-not-confirmed")
        }
        let inserted = NSRange(location: plan.range.location, length: plan.replacement.utf16.count)
        let wordCaret = NSRange(location: plan.range.location + plan.receipt.converted.utf16.count, length: 0)
        let known = [inserted, plan.finalSelection, wordCaret]
        guard let current = access.selection(in: element), known.contains(current),
              isCurrent(element, request: request), access.setSelection(plan.finalSelection, in: element) else {
            return logged(.failed, reason: "final-caret-write-failed")
        }
        let settled = await settle(
            text: plan.resultingText, selection: plan.finalSelection, allowed: known,
            in: element, isValid: { self.isCurrent(element, request: request) }
        )
        guard settled else { return logged(.failed, reason: "final-state-not-settled") }
        return logged(.success(plan.receipt), reason: "replacement-confirmed")
    }

    /// Исходная каретка может быть устаревшим readback ещё не применённого setter.
    /// Поэтому после своей попытки повторяем восстановление даже при равенстве.
    private func cleanup(_ plan: AXReplacementPlan, in element: AXUIElement, request: ConversionRequest) async {
        let allowed = { self.isCurrent(element, request: request, cleanup: true) }
        guard allowed(), let text = access.text(in: element), let selection = access.selection(in: element),
              allowed() else { return }
        let target: NSRange
        if text == plan.text, selection == plan.selection || selection == plan.range {
            target = plan.selection
        } else if let caret = plan.cleanupCaret(in: text, selection: selection) {
            target = caret
        } else { return }
        guard allowed(), access.text(in: element) == text, access.selection(in: element) == selection,
              allowed() else { return }
        _ = access.setSelection(target, in: element)
        let settled = await settle(
            text: text, selection: target, allowed: [selection, target, plan.range], in: element, isValid: allowed
        )
        logger.info("AX cleanup: каретка подтверждена=\(settled, privacy: .public)")
    }

    private func settle(
        text: String, selection: NSRange, allowed: [NSRange],
        in element: AXUIElement, isValid: () -> Bool
    ) async -> Bool {
        await SelectionSettlement.wait(
            expected: (text, selection), allowedSelections: allowed, isValid: isValid,
            read: {
                guard let text = self.access.text(in: element),
                      let selection = self.access.selection(in: element) else { return nil }
                return (text, selection)
            }, pause: { await self.access.waitForUpdate() }
        )
    }

    private func isCurrent(_ element: AXUIElement, request: ConversionRequest, cleanup: Bool = false) -> Bool {
        guard cleanup ? request.canCleanup() : request.isValid(),
              let focused = access.focusedElement(), CFEqual(focused, element) else { return false }
        return !access.isProtected(element)
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
