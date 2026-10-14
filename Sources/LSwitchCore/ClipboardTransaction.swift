import Foundation
import os

/// Состояние одной операции удерживается через await; каждый следующий шаг
/// заново подтверждает фокус и владельца clipboard.
@MainActor
final class ClipboardTransaction {
    let request: ConversionRequest
    let configuration: ClipboardConverter.Configuration
    let environment: ClipboardEnvironment
    let transform: (@Sendable (String) -> String)?
    let logger = Logger(subsystem: "LSwitch", category: "Clipboard")
    var context: ClipboardEnvironment.Context?
    var snapshot: PasteboardSnapshot?
    var initialCount = 0
    var ownedCount: Int?
    var createdSelection = false
    var pasted = false
    var existingSelection: String?
    var verifiedPlan: AXReplacementPlan?
    var observedSelection: NSRange?
    var mutationDenied = false
    var legacySelection: String?
    var legacyState: ClipboardEnvironment.TextState?

    typealias Parts = (word: String, tail: String)

    struct PastePlan {
        let parts: Parts
        let converted: String
        let original: String
        let inserted: String
        let expectation: PasteExpectation?
    }

    struct PasteExpectation {
        let before: ClipboardEnvironment.TextState
        let expectedText: String
        let insertedRange: NSRange

        func isConfirmed(_ state: ClipboardEnvironment.TextState) -> Bool {
            state.text == expectedText && state.selection == NSRange(location: NSMaxRange(insertedRange), length: 0)
        }

        func recognizesSelection(_ state: ClipboardEnvironment.TextState) -> Bool {
            (state.text == before.text && state.selection == before.selection) ||
                (state.text == expectedText && state.selection == insertedRange)
        }
    }

    init(
        request: ConversionRequest,
        configuration: ClipboardConverter.Configuration,
        environment: ClipboardEnvironment,
        transform: (@Sendable (String) -> String)?
    ) {
        self.request = request
        self.configuration = configuration
        self.environment = environment
        self.transform = transform
    }

    func run() async -> ConversionResult {
        guard request.isValid(), let context = environment.captureContext(), context.isValid() else { return .blocked }
        self.context = context
        environment.prepare({ self.valid })
        // Поиск меню выполняется до выделения. Пауза позволяет обработать ввод,
        // поступивший за время поиска, и отменить устаревший запрос до первых клавиш.
        await environment.sleep(configuration.preCopyDelay)
        guard valid else { return .blocked }
        if let state = context.readState() {
            guard let plan = AXReplacementPlan(
                text: state.text, selection: state.selection, request: request, transform: convertedWord
            ) else {
                logger.notice("Clipboard отказ до выделения: снимок AX не соответствует запросу")
                return .blocked
            }
            return await finish(await performVerified(plan))
        }
        // Автоматика не создаёт выделение, пока нет проверяемого исходного текста.
        // Явная ручная команда и точный undo сохраняют clipboard fallback.
        guard request.useSelection || request.replacement != nil else {
            logger.notice("Clipboard auto отказ до выделения: нет AX-снимка")
            return .blocked
        }
        guard captureClipboard() else { return .blocked }
        let selected = request.useSelection ? context.selectedText() : nil
        existingSelection = selected.flatMap { $0.isEmpty ? nil : $0 }
        guard beginMutationIfValid() else { return .blocked }
        if existingSelection == nil {
            let command = request.expectedSpan.map { ClipboardCommand.selectCharacters($0.count) } ?? .selectWord
            createdSelection = true
            let selected = await send(command)
            rememberLegacySelection()
            guard selected else { return await finish(valid ? .unavailable : .blocked) }
        }
        // Cmd+C идёт сразу за выделением в той же очереди. Лишняя пауза здесь
        // оставила бы дополнительное окно для пользовательского ввода.
        let result = await copyAndPaste()
        return await finish(result)
    }

    var valid: Bool {
        request.isValid() && context?.isValid() == true && !Task.isCancelled
    }

    var cleanupAllowed: Bool {
        request.canCleanup() && context?.isValid() == true
    }

    func rememberLegacySelection() {
        guard cleanupAllowed else { return }
        legacySelection = context?.selectedText()
        legacyState = context?.readState()
    }

    func beginMutationIfValid() -> Bool {
        guard valid else { return false }
        return request.beginMutation() && valid
    }

    func copyAndPaste() async -> ConversionResult {
        var delay = configuration.initialReadDelay
        for attempt in 1...max(1, configuration.maxAttempts) {
            guard valid, environment.changeCount() == (ownedCount ?? initialCount) else { return .blocked }
            let beforeCopy = environment.changeCount()
            guard await send(.copy) else { return valid ? .unavailable : .blocked }
            if environment.changeCount() == beforeCopy { await environment.sleep(delay) }
            guard valid else { return .blocked }
            let afterCopy = environment.changeCount()
            guard afterCopy != beforeCopy else {
                // Повторяем только Cmd+C: новое ⇧← расширило бы выделение.
                logger.notice("Копирование не завершено, попытка \(attempt)")
                delay *= 2
                continue
            }
            guard let copied = environment.string(), !copied.isEmpty, let parts = matchingParts(copied) else {
                // Неизвестный текст мог прийти от чужого Cmd+C. Не присваиваем его
                // changeCount и не затираем старым снимком при завершении.
                logger.notice("Выделенный фрагмент не совпал с запросом")
                return .unavailable
            }
            ownedCount = afterCopy
            return await paste(parts: parts)
        }
        return .unavailable
    }

    func matchingParts(_ copied: String) -> (word: String, tail: String)? {
        if let existingSelection { return copied == existingSelection ? (existingSelection, "") : nil }
        return request.matchingParts(in: copied)
    }

    func paste(parts: Parts) async -> ConversionResult {
        guard let plan = preparePaste(copied: parts) else { return .unavailable }
        guard valid, environment.changeCount() == ownedCount else { return .blocked }
        let written = environment.write(plan.inserted)
        ownedCount = written.changeCount
        guard written.succeeded else { return .unavailable }
        guard environment.changeCount() == ownedCount else { return .blocked }
        // setString завершает запись синхронно; получатель читает уже готовый clipboard.
        guard valid else { return .blocked }
        pasted = true
        guard await send(.paste) else {
            await cleanupPaste(expectation: plan.expectation, original: plan.original, inserted: plan.inserted)
            return .failed
        }
        let confirmed = await confirmPaste(
            expectation: plan.expectation, original: plan.original, inserted: plan.inserted
        )
        guard confirmed else { return .failed }
        logger.info("Clipboard-конвертация завершена")
        return .success(ConversionReceipt(
            original: plan.parts.word, converted: plan.converted, trailingText: plan.parts.tail
        ))
    }

    func preparePaste(copied: Parts) -> PastePlan? {
        var actual = copied
        let selectedText = context?.selectedText()
        let selected = selectedText.flatMap { $0.isEmpty ? nil : $0 }
        if let selected {
            guard let matched = compatibleParts(selected, copied: copied) else {
                logger.notice("Clipboard отказ: AXSelectedText не соответствует скопированному слову")
                return nil
            }
            actual = matched
        }
        var reliableState: ClipboardEnvironment.TextState?
        if let before = context?.readState() {
            let span = Range(before.selection, in: before.text).map { String(before.text[$0]) }
            if let selected {
                if span == selected {
                    reliableState = before
                } else {
                    logger.notice("Clipboard: AX-диапазон недостоверен; AXSelectedText подтверждает фрагмент")
                }
            } else if let span, let matched = compatibleParts(span, copied: copied) {
                actual = matched
                reliableState = before
            } else {
                logger.notice("Clipboard отказ: AX-диапазон расходится с копированием без AXSelectedText")
                return nil
            }
        }
        let converted = convertedWord(actual.word)
        let original = actual.word + actual.tail
        let inserted = converted + actual.tail
        let expectation = reliableState.flatMap { makeExpectation(before: $0, original: original, inserted: inserted) }
        return PastePlan(parts: actual, converted: converted, original: original, inserted: inserted,
                         expectation: expectation)
    }

    func compatibleParts(_ text: String, copied: Parts) -> Parts? {
        if existingSelection != nil { return text == copied.word + copied.tail ? copied : nil }
        if request.expectedWord != nil { return request.matchingParts(in: text) }
        return text == copied.word + copied.tail ? copied : nil
    }

    func convertedWord(_ word: String) -> String {
        if let transform, request.replacement == nil, request.sourceLayout == nil { return transform(word) }
        return request.converted(word)
    }

    func makeExpectation(
        before: ClipboardEnvironment.TextState,
        original: String,
        inserted: String
    ) -> PasteExpectation? {
        guard let range = Range(before.selection, in: before.text), String(before.text[range]) == original else {
            return nil
        }
        var expectedText = before.text
        expectedText.replaceSubrange(range, with: inserted)
        return PasteExpectation(
            before: before,
            expectedText: expectedText,
            insertedRange: NSRange(location: before.selection.location, length: inserted.utf16.count)
        )
    }

    func send(_ command: ClipboardCommand) async -> Bool {
        guard valid else { return false }
        let sent = await environment.send(command, {
            self.valid && (command != .paste || self.environment.changeCount() == self.ownedCount)
        })
        return sent && valid
    }

    func collapseSelection() async -> Bool {
        guard cleanupAllowed else { return false }
        guard await environment.send(.collapseSelection, { self.cleanupAllowed }) else { return false }
        if cleanupAllowed && context?.selectedText()?.isEmpty == true { return true }
        await environment.sleep(configuration.writeDelay)
        guard cleanupAllowed else { return false }
        return context?.selectedText()?.isEmpty == true
    }

    func finish(_ result: ConversionResult) async -> ConversionResult {
        var finalResult = result
        if createdSelection && !pasted && cleanupAllowed, !(await cleanupLegacySelection()) {
            finalResult = .failed
        }
        if let snapshot, let ownedCount, environment.changeCount() == ownedCount {
            environment.restore(snapshot)
            logger.info("Снимок буфера восстановлен")
        }
        return finalResult
    }
}
