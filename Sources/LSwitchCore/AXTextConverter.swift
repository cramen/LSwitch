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
    private let receiverContract: AXReceiverContract?
    private let observationProfile: AXObservationProfile?
    private let logger = Logger(subsystem: "LSwitch", category: "AXConverter")

    public convenience init(transform: @escaping (String) -> String = { LayoutMap.shared.invert($0) }) {
        self.init(access: SystemAXTextAccess(), transform: transform)
    }

    init(
        access: any AXTextAccess,
        transform: @escaping (String) -> String = { LayoutMap.shared.invert($0) },
        receiverContract: AXReceiverContract? = nil,
        observationProfile: AXObservationProfile? = nil
    ) {
        self.access = access
        self.transform = transform
        self.receiverContract = receiverContract
        self.observationProfile = observationProfile
    }

    public func perform(_ request: ConversionRequest) async -> ConversionResult {
        await performWithEvidence(request).result
    }

    func performWithEvidence(_ request: ConversionRequest) async -> AXConversionExecution {
        await performWithEvidence(request, transform: request.converted)
    }

    /// Обёртка для диагностического режима; основной путь использует явный запрос.
    public func convert() async -> Result<Outcome, AXConvertError> {
        let execution = await performWithEvidence(ConversionRequest(), transform: transform)
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

    private func performWithEvidence(
        _ request: ConversionRequest, transform: (String) -> String
    ) async -> AXConversionExecution {
        let mutation = AXMutationSafety(request: request, receiverContract: receiverContract,
                                        profile: observationProfile)
        let execution = await execute(request, transform: transform, mutation: mutation)
        switch execution.result {
        case .success: break
        case .unavailable where mutation.permitsNoWorkResult: break
        default: mutation.failProfile(.snapshotMismatch)
        }
        mutation.finishEvidence()
        let result: ConversionResult
        if case .success = execution.result, request.safetyLedger != nil,
           !mutation.permitsReceipt || mutation.cleanup != .recoveredObserved || Task.isCancelled {
            result = logged(.failed, reason: "final-evidence-unconfirmed")
        } else if case .success = execution.result {
            result = logged(execution.result, reason: "replacement-confirmed")
        } else {
            result = execution.result
        }
        return AXConversionExecution(result: result, wasSelection: execution.wasSelection, cleanup: mutation.cleanup)
    }

    private func execute(
        _ request: ConversionRequest,
        transform: (String) -> String,
        mutation: AXMutationSafety
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
        guard mutation.bind(to: element) else {
            return (logged(.blocked, reason: "receiver-contract-unavailable"), false)
        }
        guard let initial = initialState(in: element, mutation: mutation) else {
            return (logged(.unavailable, reason: "snapshot-or-plan-unavailable"), false)
        }
        guard let plan = AXReplacementPlan(text: initial.text, selection: initial.selection,
                                           request: request, transform: transform) else {
            let reason = mutation.observeNoWork(initial) ? "no-word-observed" : "snapshot-or-plan-unavailable"
            return (logged(.unavailable, reason: reason), false)
        }
        guard request.permitsAutomaticContext(context, plan: plan), isCurrent(element, request: request) else {
            return (logged(.blocked, reason: "automatic-context-not-permitted"), plan.wasSelection)
        }
        guard access.canReplaceText(in: element), access.canSetSelection(in: element) else {
            return (logged(.unavailable, reason: "attributes-not-settable"), plan.wasSelection)
        }
        let result = await replace(plan, in: element, request: request, mutation: mutation)
        await recordFinalCleanup(result, plan: plan, in: element, request: request, mutation: mutation)
        if case .success(let receipt) = result {
            return (.success(receipt.checkingTarget(targetCheck)), plan.wasSelection)
        }
        return (result, plan.wasSelection)
    }

    private func recordFinalCleanup(
        _ result: ConversionResult, plan: AXReplacementPlan, in element: AXUIElement,
        request: ConversionRequest, mutation: AXMutationSafety
    ) async {
        guard mutation.attempted else { return }
        switch result {
        case .success:
            mutation.recordCleanup(.recoveredObserved) {
                if mutation.isProfileMode {
                    return self.isCurrent(element, request: request)
                        && mutation.observeProfileFinal(.init(plan.resultingText, plan.finalSelection))
                        && self.isCurrent(element, request: request)
                }
                return self.isCurrent(element, request: request)
                    && mutation.textMatches(self.access.text(in: element), plan.resultingText)
                    && self.access.selection(in: element) == plan.finalSelection
                    && self.isCurrent(element, request: request)
            }
        default:
            mutation.failProfile(Task.isCancelled ? .cancelled : .snapshotMismatch)
            if mutation.isProfileMode {
                mutation.recordCleanup(.recoveryUnconfirmed, validateFresh: { false })
                return
            }
            let evidence = await cleanup(plan, in: element, request: request, mutation: mutation)
            if evidence != .recoveredObserved { mutation.recordCleanup(evidence, validateFresh: { false }) }
        }
    }

    private func replace(
        _ plan: AXReplacementPlan,
        in element: AXUIElement,
        request: ConversionRequest,
        mutation: AXMutationSafety
    ) async -> ConversionResult {
        guard isCurrent(element, request: request),
              matchesState(.init(plan.text, plan.selection), in: element, mutation: mutation) else {
            return logged(.blocked, reason: "snapshot-changed-before-selection")
        }
        guard request.beginMutation(), isCurrent(element, request: request) else {
            return logged(.blocked, reason: "input-hold-unavailable")
        }
        if plan.range != plan.selection {
            guard mutation.writeSelection(plan.range, in: element, access: access,
                                          isValid: { self.isCurrent(element, request: request) }) else {
                return logged(.failed, reason: "selection-write-failed")
            }
            let settled = await settle(
                expected: (plan.text, plan.range), allowed: [plan.selection, plan.range],
                in: element, mutation: mutation, isValid: { self.isCurrent(element, request: request) }
            )
            guard settled else {
                let result: ConversionResult = isCurrent(element, request: request) ? .failed : .blocked
                return logged(result, reason: "selection-not-settled")
            }
            guard mutation.requireCompletion(.selectedRangeSettled, expected: .init(plan.text, plan.range)) else {
                return logged(.failed, reason: "selection-completion-unconfirmed")
            }
        }
        guard isCurrent(element, request: request),
              matchesState(.init(plan.text, plan.range), in: element, mutation: mutation) else {
            return logged(.blocked, reason: "context-changed-after-selection")
        }
        guard mutation.writeText(plan.replacement, in: element, access: access,
                                 isValid: { self.isCurrent(element, request: request) }) else {
            return logged(.failed, reason: "text-write-failed")
        }
        return await finishWrite(plan, in: element, request: request, mutation: mutation)
    }

    private func finishWrite(
        _ plan: AXReplacementPlan,
        in element: AXUIElement,
        request: ConversionRequest,
        mutation: AXMutationSafety
    ) async -> ConversionResult {
        guard isCurrent(element, request: request),
              mutation.isProfileMode || mutation.textMatches(access.text(in: element), plan.resultingText) else {
            return logged(.failed, reason: "text-write-not-confirmed")
        }
        let inserted = NSRange(location: plan.range.location, length: plan.replacement.utf16.count)
        let wordCaret = NSRange(location: plan.range.location + plan.receipt.converted.utf16.count, length: 0)
        let known = [inserted, plan.finalSelection, wordCaret]
        guard mutation.requireCompletion(.replacementObserved,
                                         expected: .init(text: plan.resultingText, selections: known)) else {
            return logged(.failed, reason: "text-completion-unconfirmed")
        }
        let current = mutation.isProfileMode
            ? mutation.profileRead(.init(text: plan.resultingText, selections: known))?.selection
            : access.selection(in: element)
        guard let current, known.contains(current),
              isCurrent(element, request: request),
              mutation.writeSelection(plan.finalSelection, in: element, access: access, restoring: true,
                                      isValid: { self.isCurrent(element, request: request) }) else {
            return logged(.failed, reason: "final-caret-write-failed")
        }
        let settled = await settle(
            expected: (plan.resultingText, plan.finalSelection), allowed: known,
            in: element, mutation: mutation, isValid: { self.isCurrent(element, request: request) }
        )
        guard settled else { return logged(.failed, reason: "final-state-not-settled") }
        guard mutation.requireCompletion(.finalStateSettled,
                                         expected: .init(plan.resultingText, plan.finalSelection)) else {
            return logged(.failed, reason: "final-caret-completion-unconfirmed")
        }
        return .success(plan.receipt)
    }

    /// Исходная каретка может быть устаревшим readback ещё не применённого setter.
    /// Поэтому после своей попытки повторяем восстановление даже при равенстве.
    private func cleanup(
        _ plan: AXReplacementPlan, in element: AXUIElement, request: ConversionRequest, mutation: AXMutationSafety
    ) async -> ConversionSafetyCleanupEvidence {
        let allowed = { self.isCurrent(element, request: request, cleanup: true) }
        guard allowed(), let text = access.text(in: element), let selection = access.selection(in: element),
              allowed() else { return .recoveryUnconfirmed }
        let target: NSRange
        if mutation.textMatches(text, plan.text), selection == plan.selection || selection == plan.range {
            target = plan.selection
        } else if let caret = mutation.cleanupCaret(plan, text: text, selection: selection) {
            target = caret
        } else { return .recoveryUnconfirmed }
        guard allowed(), mutation.textMatches(access.text(in: element), text),
              access.selection(in: element) == selection,
              allowed() else { return .recoveryUnconfirmed }
        _ = mutation.writeSelection(target, in: element, access: access, restoring: true, isValid: allowed)
        let settled = await settle(
            expected: (text, target), allowed: [selection, target, plan.range],
            in: element, mutation: mutation, isValid: allowed
        )
        logger.info("AX cleanup: каретка подтверждена=\(settled, privacy: .public)")
        guard settled else { return .recoveryUnconfirmed }
        return mutation.recordCleanup(.recoveredObserved) {
            allowed() && mutation.textMatches(self.access.text(in: element), text)
                && self.access.selection(in: element) == target && allowed()
        }
    }

    private func settle(
        expected: SelectionSettlement.State, allowed: [NSRange],
        in element: AXUIElement, mutation: AXMutationSafety, isValid: () -> Bool
    ) async -> Bool {
        await SelectionSettlement.wait(
            expected: expected, allowedSelections: allowed, isValid: isValid,
            read: {
                if mutation.isProfileMode {
                    guard let snapshot = mutation.profileRead(.init(expected.text, expected.selection)) else {
                        return nil
                    }
                    return (snapshot.text, snapshot.selection)
                }
                guard let text = self.access.text(in: element),
                      let selection = self.access.selection(in: element),
                      mutation.textMatches(text, expected.text) else { return nil }
                return (text, selection)
            }, pause: { await self.access.waitForUpdate() }
        )
    }

    private func isCurrent(_ element: AXUIElement, request: ConversionRequest, cleanup: Bool = false) -> Bool {
        let tracked = request.safetyLedger != nil
        guard cleanup || !tracked || !Task.isCancelled,
              cleanup ? request.canCleanup() : request.isValid(),
              let focused = access.focusedElement(), CFEqual(focused, element) else { return false }
        return !access.isProtected(element) && (cleanup || !tracked || !Task.isCancelled)
    }

    private func initialState(in element: AXUIElement, mutation: AXMutationSafety)
        -> SelectionSettlement.State? {
        if mutation.isProfileMode {
            guard let snapshot = mutation.profileRead(nil) else { return nil }
            return (snapshot.text, snapshot.selection)
        }
        guard let text = access.text(in: element), let selection = access.selection(in: element) else { return nil }
        return (text, selection)
    }

    private func matchesState(
        _ expected: AXProfileExpectedState, in element: AXUIElement, mutation: AXMutationSafety
    ) -> Bool {
        if mutation.isProfileMode { return mutation.profileRead(expected) != nil }
        return mutation.textMatches(access.text(in: element), expected.text)
            && access.selection(in: element) == expected.selections.first
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

extension AXTextConverter {
    public static func isSecureField(_ element: AXUIElement) -> Bool {
        SystemAXTextAccess.isSecureField(element)
    }

    public func focusedElement() -> AXUIElement? { access.focusedElement() }
}
