import ApplicationServices
import Foundation
import os

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
        if mutation.isCanonicalProfileCandidate, !mutation.bind(to: element) {
            return (logged(.blocked, reason: "receiver-contract-unavailable"), false)
        }
        guard let scope = AXTextConversionScope(request: request, element: element, access: access, mutation: mutation)
        else { return (.blocked, false) }
        let request = scope.request
        guard isCurrent(element, request: request, mutation: mutation) else { return (.blocked, false) }
        guard mutation.hasCanonicalProfileBoundary || mutation.bind(to: element, validating: request) else {
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
        guard request.permitsAutomaticContext(scope.context, plan: plan),
              isCurrent(element, request: request, mutation: mutation) else {
            return (logged(.blocked, reason: "automatic-context-not-permitted"), plan.wasSelection)
        }
        guard access.canReplaceText(in: element), access.canSetSelection(in: element) else {
            return (logged(.unavailable, reason: "attributes-not-settable"), plan.wasSelection)
        }
        let result = await replace(plan, in: element, request: request, mutation: mutation)
        await recordFinalCleanup(result, plan: plan, in: element, request: request, mutation: mutation)
        if case .success(let receipt) = result {
            return (.success(scope.wrap(receipt, finalSelection: plan.finalSelection)), plan.wasSelection)
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
                    return self.isCurrent(element, request: request, mutation: mutation)
                        && mutation.observeProfileFinal(.init(plan.resultingText, plan.finalSelection))
                        && self.isCurrent(element, request: request, mutation: mutation)
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
        guard isCurrent(element, request: request, mutation: mutation),
              matchesState(.init(plan.text, plan.selection), in: element, mutation: mutation) else {
            return logged(.blocked, reason: "snapshot-changed-before-selection")
        }
        guard request.beginMutation(), isCurrent(element, request: request, mutation: mutation) else {
            return logged(.blocked, reason: "input-hold-unavailable")
        }
        if plan.range != plan.selection {
            guard writeSelection(plan.range, in: element, request: request, mutation: mutation) else {
                return logged(.failed, reason: "selection-write-failed")
            }
            let settled = await settle(
                expected: (plan.text, plan.range), allowed: [plan.selection, plan.range],
                in: element, mutation: mutation,
                observation: .selectedRangeSettled,
                isValid: { self.isCurrent(element, request: request, mutation: mutation) }
            )
            guard settled else {
                let result: ConversionResult = isCurrent(element, request: request, mutation: mutation)
                    ? .failed : .blocked
                return logged(result, reason: "selection-not-settled")
            }
            guard mutation.hasCanonicalProfileBoundary
                || mutation.requireCompletion(.selectedRangeSettled, expected: .init(plan.text, plan.range)) else {
                return logged(.failed, reason: "selection-completion-unconfirmed")
            }
        }
        guard isCurrent(element, request: request, mutation: mutation),
              matchesState(.init(plan.text, plan.range), in: element, mutation: mutation) else {
            return logged(.blocked, reason: "context-changed-after-selection")
        }
        guard writeText(plan.replacement, in: element, request: request, mutation: mutation) else {
            return logged(.failed, reason: "text-write-failed")
        }
        return await finishWrite(plan, in: element, request: request, mutation: mutation)
    }
}

extension AXTextConverter {
    private func writeSelection(
        _ range: NSRange, in element: AXUIElement, request: ConversionRequest,
        mutation: AXMutationSafety, restoring: Bool = false
    ) -> Bool {
        if mutation.hasCanonicalProfileBoundary {
            return mutation.writeCanonicalSelection(range, in: element, access: access, restoring: restoring)
        }
        return mutation.writeSelection(range, in: element, access: access, restoring: restoring,
                                       isValid: { self.isCurrent(element, request: request) })
    }

    private func writeText(
        _ text: String, in element: AXUIElement, request: ConversionRequest, mutation: AXMutationSafety
    ) -> Bool {
        if mutation.hasCanonicalProfileBoundary {
            return mutation.writeCanonicalText(text, in: element, access: access)
        }
        return mutation.writeText(text, in: element, access: access,
                                  isValid: { self.isCurrent(element, request: request) })
    }

    private func finishWrite(
        _ plan: AXReplacementPlan,
        in element: AXUIElement,
        request: ConversionRequest,
        mutation: AXMutationSafety
    ) async -> ConversionResult {
        guard isCurrent(element, request: request, mutation: mutation),
              mutation.isProfileMode || mutation.textMatches(access.text(in: element), plan.resultingText) else {
            return logged(.failed, reason: "text-write-not-confirmed")
        }
        let inserted = NSRange(location: plan.range.location, length: plan.replacement.utf16.count)
        let wordCaret = NSRange(location: plan.range.location + plan.receipt.converted.utf16.count, length: 0)
        let known = [inserted, plan.finalSelection, wordCaret]
        let current: NSRange?
        if mutation.isProfileMode {
            guard let observed = mutation.confirmedProfileReplacementSelection(
                .init(text: plan.resultingText, selections: known)
            ) else { return logged(.failed, reason: "text-completion-unconfirmed") }
            current = observed
        } else {
            guard mutation.requireCompletion(.replacementObserved) else {
                return logged(.failed, reason: "text-completion-unconfirmed")
            }
            current = access.selection(in: element)
        }
        guard let current, known.contains(current),
              isCurrent(element, request: request, mutation: mutation),
              writeSelection(plan.finalSelection, in: element, request: request,
                             mutation: mutation, restoring: true) else {
            return logged(.failed, reason: "final-caret-write-failed")
        }
        let settled = await settle(
            expected: (plan.resultingText, plan.finalSelection), allowed: known,
            in: element, mutation: mutation,
            observation: .finalStateSettled,
            isValid: { self.isCurrent(element, request: request, mutation: mutation) }
        )
        guard settled else { return logged(.failed, reason: "final-state-not-settled") }
        guard mutation.hasCanonicalProfileBoundary || mutation.requireCompletion(.finalStateSettled,
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
        in element: AXUIElement, mutation: AXMutationSafety,
        observation: AXWriteObservation? = nil, isValid: () -> Bool
    ) async -> Bool {
        if mutation.hasCanonicalProfileBoundary, let observation {
            return await mutation.settleCanonical(observation, expected: .init(expected.text, expected.selection),
                                                  pause: { await self.access.waitForUpdate() })
        }
        return await SelectionSettlement.wait(
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

    private func isCurrent(
        _ element: AXUIElement, request: ConversionRequest, mutation: AXMutationSafety? = nil, cleanup: Bool = false
    ) -> Bool {
        if !cleanup, let mutation, mutation.hasCanonicalProfileBoundary { return mutation.canonicalProfileIsCurrent() }
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
