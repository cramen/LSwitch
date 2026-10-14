import CoreGraphics
import Dispatch
import Foundation
import os

enum ClipboardCommand: Equatable {
    case selectCharacters(Int)
    case selectWord
    case copy
    case paste
    case collapseSelection
}

/// Модификатор команды посылается отдельными flagsChanged, а Unicode клавиши
/// остаётся латинским. Electron иначе может трактовать Cmd+С в RU как обычный ввод.
enum KeyboardEmitter {
    private static let logger = Logger(subsystem: "LSwitch", category: "Keyboard")

    @MainActor
    static func send(
        _ command: ClipboardCommand,
        targetPID: pid_t,
        isValid: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard targetPID > 0, isValid(), let events = events(for: command) else { return false }
        logger.info("transport=pid targetPID=\(targetPID, privacy: .public)")
        let paced = command == .copy || command == .paste
        if !paced {
            for event in events { post(event, targetPID: targetPID) }
            return isValid()
        }
        var keyPressed = false
        var modifierPressed = false
        defer {
            // При смене контекста не посылаем следующий keyDown. Уже нажатые
            // собственные клавиши отпускаем, иначе Command может «залипнуть».
            if keyPressed, let release = events.first(where: { $0.type == .keyUp }) {
                post(release, targetPID: targetPID)
            }
            if modifierPressed, let release = events.last { post(release, targetPID: targetPID) }
        }
        for event in events {
            guard isValid() else { return false }
            post(event, targetPID: targetPID)
            if event.type == .keyDown { keyPressed = true }
            if event.type == .keyUp { keyPressed = false }
            if event.type == .flagsChanged { modifierPressed = !event.flags.isEmpty }
            // Интервал 15 мс проверен независимым драйвером в RU Obsidian.
            // Главный run loop должен обработать собственный event tap между событиями.
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return isValid()
    }

    /// Между событиями этого пакета нет await; ревизия MainActor не может измениться.
    /// Проверки AX выполняются до и после пакета, а не для каждой стрелки.
    @MainActor
    static func sendBatch(
        _ command: ClipboardCommand,
        targetPID: pid_t,
        isValid: () -> Bool,
        didPost: () -> Void = {}
    ) -> Bool {
        guard command != .copy, command != .paste, targetPID > 0, isValid(),
              let events = events(for: command) else { return false }
        for event in events { post(event, targetPID: targetPID) }
        didPost()
        return isValid()
    }

    private static func post(_ event: CGEvent, targetPID: pid_t) {
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        // Получатель захвачен среди уже активных приложений; фокус не меняем.
        event.postToPid(targetPID)
    }

    static func events(for command: ClipboardCommand) -> [CGEvent]? {
        let source = CGEventSource(stateID: .hidSystemState)
        var events: [CGEvent] = []
        switch command {
        case .copy, .paste:
            let virtualKey: CGKeyCode = command == .copy ? 0x08 : 0x09
            let unicode = command == .copy ? "c" : "v"
            guard let down = modifier(0x37, keyDown: true, flags: .maskCommand, source: source),
                  let keys = key(virtualKey, flags: .maskCommand, unicode: unicode, source: source),
                  let release = modifier(0x37, keyDown: false, flags: [], source: source) else { return nil }
            events = [down] + keys + [release]
        case .selectCharacters(let count):
            guard count > 0 else { return nil }
            for _ in 0..<count {
                guard let keys = key(0x7B, flags: .maskShift, source: source) else { return nil }
                events += keys
            }
        case .selectWord:
            guard let keys = key(0x7B, flags: [.maskAlternate, .maskShift], source: source) else { return nil }
            events = keys
        case .collapseSelection:
            guard let keys = key(0x7C, flags: [], source: source) else { return nil }
            events = keys
        }
        return events
    }

    private static func modifier(
        _ virtualKey: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource?
    ) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown) else {
            return nil
        }
        event.type = .flagsChanged
        event.flags = flags
        guard SyntheticEventMarker.tag(event) else { return nil }
        return event
    }

    private static func key(
        _ virtualKey: CGKeyCode,
        flags: CGEventFlags,
        unicode: String? = nil,
        source: CGEventSource?
    ) -> [CGEvent]? {
        var result: [CGEvent] = []
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown) else {
                return nil
            }
            event.flags = flags
            if let unicode {
                let units = Array(unicode.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            guard SyntheticEventMarker.tag(event) else { return nil }
            result.append(event)
        }
        return result
    }
}
