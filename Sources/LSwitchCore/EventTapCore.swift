import AppKit
import CoreGraphics
import Foundation
import os

/// Глобальный перехват клавиатуры через CGEventTap (спайк P0.1).
///
/// Режим listen-only на уровне сессии: события не модифицируются и не
/// блокируются. Callback только извлекает поля события в `RawKeyEvent` и
/// передаёт его в выделенную последовательную очередь — никакого I/O в
/// hot path. При отключении tap системой (timeout / user input) и после
/// sleep/wake или смены сессии tap пересоздаётся автоматически (design D3).
public final class EventTapCore {

    public typealias Handler = (RawKeyEvent) -> Void

    public enum State: Equatable {
        case stopped
        case running
        /// Tap отключён системой, идёт пересоздание.
        case recovering
    }

    private let handler: Handler
    private let processingQueue = DispatchQueue(label: "lswitch.eventtap.processing")
    private let logger = Logger(subsystem: "LSwitch", category: "EventTap")

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Сколько раз tap пересоздавался с момента запуска (диагностика спайка).
    public private(set) var recoveryCount = 0

    public private(set) var state: State = .stopped

    /// - Parameter handler: вызывается на выделенной последовательной очереди
    ///   для каждого перехваченного события (включая синтетику — фильтрация
    ///   на стороне подписчика через `RawKeyEvent.isSynthetic`).
    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    /// Создаёт и запускает event tap. Возвращает `false`, если tap не создан
    /// (нет разрешения Input Monitoring / Accessibility).
    @discardableResult
    public func start() -> Bool {
        guard state == .stopped else { return true }
        guard createTap() else {
            logger.error("Не удалось создать event tap — проверьте разрешения")
            return false
        }
        state = .running
        subscribeWorkspaceNotifications()
        logger.info("Event tap запущен")
        return true
    }

    public func stop() {
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
            CFMachPortInvalidate(machPort)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        machPort = nil
        runLoopSource = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        state = .stopped
    }

    // MARK: - Tap lifecycle

    private func createTap() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        machPort = port
        runLoopSource = source
        return true
    }

    /// Вызывается из C-callback. Возвращаемое событие система доставляет
    /// дальше без изменений (listen-only).
    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            scheduleRecovery(reason: type == .tapDisabledByTimeout ? "timeout" : "userInput")
            return Unmanaged.passUnretained(event)
        }

        guard let raw = Self.makeRawEvent(type: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }
        processingQueue.async { [handler] in handler(raw) }
        return Unmanaged.passUnretained(event)
    }

    private func scheduleRecovery(reason: String) {
        processingQueue.async { [weak self] in
            guard let self, self.state != .stopped else { return }
            self.state = .recovering
            self.recoveryCount += 1
            self.logger.notice("Event tap отключён системой (\(reason)), пересоздаём (#\(self.recoveryCount))")
            if let port = self.machPort {
                // Быстрый путь: просто включить обратно.
                CGEvent.tapEnable(tap: port, enable: true)
            }
            if self.machPort == nil || !self.isTapAlive {
                self.teardownTapOnly()
                if !self.createTap() {
                    self.logger.error("Пересоздание tap не удалось, повтор через 1 с")
                    self.processingQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.scheduleRecovery(reason: "retry")
                    }
                    return
                }
            }
            self.state = .running
        }
    }

    private var isTapAlive: Bool {
        guard let machPort else { return false }
        return CGEvent.tapIsEnabled(tap: machPort)
    }

    private func teardownTapOnly() {
        if let machPort {
            CFMachPortInvalidate(machPort)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        machPort = nil
        runLoopSource = nil
    }

    // MARK: - Sleep/wake и смена сессии

    private func subscribeWorkspaceNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.processingQueue.async { [weak self] in
                    guard let self, self.state == .running, !self.isTapAlive else { return }
                    self.logger.notice("Потерян tap после \(name.rawValue), пересоздаём")
                    self.scheduleRecovery(reason: name.rawValue)
                }
            }
            workspaceObservers.append(observer)
        }
    }

    // MARK: - Извлечение события

    private static func makeRawEvent(type: CGEventType, event: CGEvent) -> RawKeyEvent? {
        let rawType: RawKeyEventType
        switch type {
        case .keyDown: rawType = .keyDown
        case .keyUp: rawType = .keyUp
        case .flagsChanged: rawType = .flagsChanged
        default: return nil
        }

        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        var characters = ""
        if length > 0 {
            var buffer = [UniChar](repeating: 0, count: length)
            event.keyboardGetUnicodeString(
                maxStringLength: length,
                actualStringLength: &length,
                unicodeString: &buffer
            )
            characters = String(utf16CodeUnits: buffer, count: length)
        }

        return RawKeyEvent(
            type: rawType,
            keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
            characters: characters,
            modifierFlags: event.flags.rawValue,
            isSynthetic: SyntheticEventMarker.isSynthetic(event),
            timestamp: event.timestamp
        )
    }
}

/// C-callback для CGEventTap. Извлекает EventTapCore из userInfo и делегирует.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let core = Unmanaged<EventTapCore>.fromOpaque(userInfo).takeUnretainedValue()
    return core.handleTapEvent(type: type, event: event)
}
