import AppKit
import CoreGraphics
import Foundation
import os

/// Конвертация выделенного текста через буфер обмена с полным
/// восстановлением его содержимого (спайк P0.3, design D5).
///
/// Схема: снимок буфера → Cmd+C → конвертация → Cmd+V → восстановление
/// снимка. Собственные синтезированные нажатия помечаются
/// `SyntheticEventMarker`, чтобы перехватчик их игнорировал.
/// Паузы между шагами адаптивные: базовые 20–50 мс с удвоением при неуспехе,
/// максимум `maxAttempts` попыток чтения.
public final class ClipboardConverter {

    public struct Configuration: Sendable {
        /// Пауза после Cmd+C перед первым чтением буфера, секунды.
        public var initialReadDelay: TimeInterval = 0.03
        /// Пауза после записи перед Cmd+V, секунды.
        public var writeDelay: TimeInterval = 0.02
        /// Пауза после Cmd+V перед восстановлением буфера: приложение-цель
        /// должно успеть прочитать буфер, иначе вставится старое содержимое.
        public var postPasteDelay: TimeInterval = 0.15
        /// Пауза перед первым Cmd+C: пункт меню статус-бара забирает
        /// key-фокус, целевое приложение должно успеть его вернуть.
        public var preCopyDelay: TimeInterval = 0.15
        /// Максимум попыток прочитать скопированный текст (с удвоением паузы).
        public var maxAttempts = 3

        public init() {}
    }

    public enum Outcome: Equatable {
        case success(original: String, converted: String)
        /// Cmd+C не дал нового содержимого за отведённые попытки.
        case copyFailed
    }

    private let configuration: Configuration
    private let transform: @Sendable (String) -> String
    private let logger = Logger(subsystem: "LSwitch", category: "Clipboard")

    public init(
        configuration: Configuration = Configuration(),
        transform: @escaping @Sendable (String) -> String = { LayoutMap.shared.invert($0) }
    ) {
        self.configuration = configuration
        self.transform = transform
    }

    /// Выполняет конвертацию последнего слова перед курсором через буфер.
    /// Буфер обмена восстанавливается при любом исходе.
    ///
    /// Выделение слова: если известно ожидаемое слово (из буфера ввода) —
    /// точное ⇧← × N и сверка скопированного со словом (защита от
    /// расхождения границ в Electron, где «rf;tncz» по ⌥⇧← выделялся бы
    /// фрагментом «tncz», а Cmd+C без выделения копирует всю строку).
    /// Без ожидаемого слова — ⌥⇧← как универсальный fallback.
    @discardableResult
    public func convertSelection(
        expectedWord: String? = nil,
        pasteboard: NSPasteboard = .general
    ) async -> Outcome {
        let snapshot = PasteboardService.capture(from: pasteboard)
        // Fingerprint до операции — для проверки инварианта «буфер бит-в-бит
        // идентичен» (задача 4.2): после восстановления сверяем в лог.
        let fingerprintBefore = PasteboardService.fingerprint(of: pasteboard)
        defer {
            PasteboardService.restore(snapshot, to: pasteboard)
            let restored = PasteboardService.fingerprint(of: pasteboard) == fingerprintBefore
            logger.info("Буфер восстановлен, fingerprint совпадает: \(restored)")
        }

        // Пауза на возврат фокуса из меню, затем выделяем слово слева.
        try? await Task.sleep(nanoseconds: UInt64(configuration.preCopyDelay * 1_000_000_000))
        selectWord(expectedWord: expectedWord)
        try? await Task.sleep(nanoseconds: UInt64(configuration.writeDelay * 1_000_000_000))

        var delay = configuration.initialReadDelay
        for attempt in 1...configuration.maxAttempts {
            let changeCountBefore = pasteboard.changeCount
            postShortcut(virtualKey: 0x08) // kVK_ANSI_C
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            guard pasteboard.changeCount != changeCountBefore,
                  let copied = pasteboard.string(forType: .string), !copied.isEmpty else {
                logger.notice("Cmd+C не дал результата, попытка \(attempt)/\(self.configuration.maxAttempts)")
                delay *= 2
                continue
            }
            if let expectedWord, copied != expectedWord {
                // Скопировалось не ожидаемое слово — перевыделяем и пробуем ещё раз.
                logger.notice("Скопировано не ожидаемое слово (длина \(copied.count)), попытка \(attempt)")
                selectWord(expectedWord: expectedWord)
                delay *= 2
                continue
            }
            return await paste(converted: transform(copied), original: copied, pasteboard: pasteboard)
        }
        return .copyFailed
    }

    private func selectWord(expectedWord: String?) {
        guard let expectedWord, !expectedWord.isEmpty else {
            postSelectWordLeft()
            return
        }
        for _ in 0..<expectedWord.count {
            postKey(virtualKey: 0x7B, flags: .maskShift) // ⇧←
        }
    }

    private func paste(converted: String, original: String, pasteboard: NSPasteboard) async -> Outcome {
        pasteboard.clearContents()
        pasteboard.setString(converted, forType: .string)
        try? await Task.sleep(nanoseconds: UInt64(configuration.writeDelay * 1_000_000_000))
        postShortcut(virtualKey: 0x09) // kVK_ANSI_V
        // Ждём, пока целевое приложение обработает Cmd+V, — иначе defer
        // восстановит буфер до вставки, и вставится старое содержимое.
        try? await Task.sleep(nanoseconds: UInt64(configuration.postPasteDelay * 1_000_000_000))
        logger.info("Сконвертировано через буфер: \(original) → \(converted)")
        return .success(original: original, converted: converted)
    }

    /// Синтезирует Cmd+<key> с меткой собственного события.
    private func postShortcut(virtualKey: UInt16) {
        postKey(virtualKey: virtualKey, flags: .maskCommand)
    }

    /// ⌥⇧← — выделить слово слева от курсора.
    private func postSelectWordLeft() {
        postKey(virtualKey: 0x7B, flags: [.maskAlternate, .maskShift])
    }

    private func postKey(virtualKey: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown) else {
                continue
            }
            event.flags = flags
            SyntheticEventMarker.tag(event)
            event.post(tap: .cghidEventTap)
        }
    }
}
