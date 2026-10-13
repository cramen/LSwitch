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

    /// Выполняет конвертацию выделения в активном приложении.
    /// Буфер обмена восстанавливается при любом исходе.
    @discardableResult
    public func convertSelection(pasteboard: NSPasteboard = .general) async -> Outcome {
        let snapshot = PasteboardService.capture(from: pasteboard)
        defer {
            PasteboardService.restore(snapshot, to: pasteboard)
            logger.debug("Буфер обмена восстановлен")
        }

        var delay = configuration.initialReadDelay
        for attempt in 1...configuration.maxAttempts {
            let changeCountBefore = pasteboard.changeCount
            postShortcut(virtualKey: 0x08) // kVK_ANSI_C
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            if pasteboard.changeCount != changeCountBefore,
               let copied = pasteboard.string(forType: .string), !copied.isEmpty {
                return await paste(converted: transform(copied), original: copied, pasteboard: pasteboard)
            }
            logger.notice("Cmd+C не дал результата, попытка \(attempt)/\(self.configuration.maxAttempts)")
            delay *= 2
        }
        return .copyFailed
    }

    private func paste(converted: String, original: String, pasteboard: NSPasteboard) async -> Outcome {
        pasteboard.clearContents()
        pasteboard.setString(converted, forType: .string)
        try? await Task.sleep(nanoseconds: UInt64(configuration.writeDelay * 1_000_000_000))
        postShortcut(virtualKey: 0x09) // kVK_ANSI_V
        logger.info("Сконвертировано через буфер: \(original) → \(converted)")
        return .success(original: original, converted: converted)
    }

    /// Синтезирует Cmd+<key> с меткой собственного события.
    private func postShortcut(virtualKey: UInt16) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown) else {
                continue
            }
            event.flags = .maskCommand
            SyntheticEventMarker.tag(event)
            event.post(tap: .cghidEventTap)
        }
    }
}
