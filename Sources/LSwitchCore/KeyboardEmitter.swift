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

/// Все модификаторы имеют парные flagsChanged; Unicode остаётся нативным для CGEvent.
/// Подмена Unicode физического Cmd+C нарушала Copy в Chrome при русской раскладке.
enum KeyboardEmitter {
    enum Phase: Equatable { case started, commandDown, keyDown, returned }

    private static let logger = Logger(subsystem: "LSwitch", category: "Keyboard")

    @MainActor
    struct Delivery {
        var post: (CGEvent, pid_t) -> Void
        var pause: () async -> Void
    }

    @MainActor
    static func send(
        _ command: ClipboardCommand,
        targetPID: pid_t,
        isValid: @escaping @MainActor () -> Bool,
        beforeKeyDown: @escaping @MainActor () -> Bool = { true },
        observer: @escaping @MainActor (Phase) -> Void = { _ in },
        hooks: ClipboardDispatchHooks? = nil
    ) async -> Bool {
        let delivery = Delivery(
            post: { post($0, targetPID: $1) },
            pause: { try? await Task.sleep(nanoseconds: 15_000_000) }
        )
        return await send(
            command, targetPID: targetPID, isValid: isValid, beforeKeyDown: beforeKeyDown,
            observer: observer, hooks: hooks, delivery: delivery
        )
    }

    @MainActor
    static func send(
        _ command: ClipboardCommand,
        targetPID: pid_t,
        isValid: @escaping @MainActor () -> Bool,
        beforeKeyDown: @escaping @MainActor () -> Bool,
        observer: @escaping @MainActor (Phase) -> Void = { _ in },
        hooks: ClipboardDispatchHooks? = nil,
        delivery: Delivery
    ) async -> Bool {
        observer(.started)
        defer { observer(.returned) }
        guard targetPID > 0, isValid(), let events = events(for: command) else { return false }
        #if DEBUG
        CommandUnicodeDiagnostics.record(command: command, events: events)
        #endif
        logger.info("transport=pid targetPID=\(targetPID, privacy: .public)")
        let paced = command == .copy || command == .paste
        if let hooks {
            return await sendTracked(events: events, configuration: .init(
                command: command, targetPID: targetPID, isValid: isValid, beforeKeyDown: beforeKeyDown,
                observer: observer, hooks: hooks, delivery: delivery
            ))
        }
        if !paced {
            for event in events { delivery.post(event, targetPID) }
            return isValid()
        }
        var pressed = PressedKeys()
        defer { pressed.release(events: events, targetPID: targetPID, delivery: delivery) }
        for event in events {
            guard isValid() else { return false }
            if event.type == .keyDown {
                guard beforeKeyDown(), isValid() else { return false }
            }
            delivery.post(event, targetPID)
            pressed.record(event, observer: observer)
            // Интервал 15 мс проверен независимым драйвером в RU Obsidian.
            // Главный run loop должен обработать собственный event tap между событиями.
            await delivery.pause()
        }
        return isValid()
    }

    @MainActor
    private struct PressedKeys {
        var keyPressed = false
        var modifierPressed = false

        mutating func record(_ event: CGEvent, observer: @MainActor (Phase) -> Void) {
            switch event.type {
            case .keyDown: keyPressed = true; observer(.keyDown)
            case .keyUp: keyPressed = false
            case .flagsChanged:
                modifierPressed = !event.flags.isEmpty
                if modifierPressed { observer(.commandDown) }
            default: break
            }
        }

        func release(events: [CGEvent], targetPID: pid_t, delivery: Delivery) {
            // При смене контекста отпускаем лишь уже отправленные собственные клавиши.
            if keyPressed, let release = events.first(where: { $0.type == .keyUp }) {
                delivery.post(release, targetPID)
            }
            if modifierPressed, let release = events.last { delivery.post(release, targetPID) }
        }
    }

    /// Между событиями этого пакета нет await; ревизия MainActor не может измениться.
    /// Проверки AX выполняются до и после пакета, а не для каждой стрелки.
    @MainActor
    static func sendBatch(
        _ command: ClipboardCommand,
        targetPID: pid_t,
        isValid: () -> Bool,
        didPost: () -> Void = {},
        afterBatch: (() -> Bool)? = nil
    ) -> Bool {
        guard command != .copy, command != .paste, targetPID > 0, isValid(),
              let events = events(for: command) else { return false }
        for event in events { post(event, targetPID: targetPID) }
        didPost()
        // Некоторые операции меняют проверяемый диапазон уже до возврата post.
        // Старые клиенты по умолчанию сохраняют прежнюю проверку после пакета.
        return afterBatch?() ?? isValid()
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
            guard let down = modifier(0x37, keyDown: true, flags: .maskCommand, source: source),
                  let keys = key(virtualKey, flags: .maskCommand, source: source),
                  let release = modifier(0x37, keyDown: false, flags: [], source: source) else { return nil }
            events = [down] + keys + [release]
        case .selectCharacters(let count):
            return selection(count: count, wholeWord: false, source: source)
        case .selectWord:
            return selection(count: 1, wholeWord: true, source: source)
        case .collapseSelection:
            guard let keys = key(0x7C, flags: [], source: source) else { return nil }
            events = keys
        }
        return events
    }

    private static func selection(count: Int, wholeWord: Bool, source: CGEventSource?) -> [CGEvent]? {
        guard count > 0,
              let shiftDown = modifier(0x38, keyDown: true, flags: .maskShift, source: source),
              let shiftUp = modifier(0x38, keyDown: false, flags: [], source: source) else { return nil }
        let flags: CGEventFlags = wholeWord ? [.maskAlternate, .maskShift] : .maskShift
        var events = [shiftDown]
        if wholeWord {
            guard let optionDown = modifier(0x3A, keyDown: true, flags: flags, source: source) else { return nil }
            events.append(optionDown)
        }
        for _ in 0..<count {
            guard let keys = key(0x7B, flags: flags, source: source) else { return nil }
            events += keys
        }
        if wholeWord {
            guard let optionUp = modifier(0x3A, keyDown: false, flags: .maskShift, source: source) else { return nil }
            events.append(optionUp)
        }
        events.append(shiftUp)
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
        source: CGEventSource?
    ) -> [CGEvent]? {
        var result: [CGEvent] = []
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown) else {
                return nil
            }
            event.flags = flags
            guard SyntheticEventMarker.tag(event) else { return nil }
            result.append(event)
        }
        return result
    }
}
