import AppKit
import CoreGraphics
import Dispatch
import Foundation
import os

/// Глобальный перехват клавиатуры через CGEventTap (спайк P0.1).
///
/// Доставка следующей клавиши ждёт завершения синхронной замены на главном потоке.
/// Для уже ожидавших клавиш исправляется Unicode после подтверждённой смены раскладки;
/// остальные события возвращаются без изменений.
/// Callback только извлекает поля события в `RawKeyEvent` и
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
    private let correctionLock = NSLock()
    private var queuedInputCorrection: QueuedInputCorrection?
    private let inputBuffer = InputEventBuffer()

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

    public var isInputHeld: Bool { inputBuffer.isHolding }

    @MainActor
    public func beginInputHold() -> Bool {
        guard state == .running,
              let generation = inputBuffer.begin(at: DispatchTime.now().uptimeNanoseconds) else { return false }
        processingQueue.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            self?.inputBuffer.expire(generation: generation, at: DispatchTime.now().uptimeNanoseconds)
        }
        logger.info("Очередь ввода: начало секции замены")
        return true
    }

    @MainActor
    public func endInputHold() {
        releaseInput()
        if state == .stopped { finishStoppedTap() }
    }

    private func releaseInput() {
        var delivered = 0
        inputBuffer.end { event in
            delivered += 1
            if let raw = correctedRawEvent(type: event.type, event: event), state != .stopped {
                processingQueue.async { [handler] in handler(raw) }
            }
            // AnnotatedSession находится ниже нашего session tap: повторного удержания нет,
            // userData сохраняется, а следующие системные получатели видят исходный порядок.
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
        if delivered > 0 { logger.info("Очередь ввода: доставлено событий \(delivered, privacy: .public)") }
    }

    /// Вызывается сразу после подтверждения TIS, до возврата главному run loop.
    @MainActor
    public func recordLayoutChange(from: Layout, to target: Layout, since startedAt: UInt64) {
        let completedAt = DispatchTime.now().uptimeNanoseconds
        guard from != target, startedAt <= completedAt else { return }
        let correction = QueuedInputCorrection(
            from: from, to: target, startedAt: startedAt, completedAt: completedAt
        )
        correctionLock.lock()
        queuedInputCorrection = correction
        correctionLock.unlock()
    }

    deinit {
        // Не захватываем уничтожаемый self асинхронно. Наблюдатели удаляются на main.
        let observers = workspaceObservers
        DispatchQueue.main.async {
            observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        }
        releaseInput()
        teardownTapOnly()
    }

    /// Создаёт tap и его наблюдателей на главном потоке.
    @MainActor
    @discardableResult
    public func start() -> Bool {
        guard !inputBuffer.isActive else { return false }
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

    @MainActor
    public func stop() {
        state = .stopped
        inputBuffer.cancelLease()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        // Владелец операции вызовет endInputHold после cleanup. До этого ввод остаётся в очереди.
        if !inputBuffer.isActive { finishStoppedTap() }
    }

    private func finishStoppedTap() {
        teardownTapOnly()
        correctionLock.lock()
        queuedInputCorrection = nil
        correctionLock.unlock()
    }

    // MARK: - Tap lifecycle

    private func createTap() -> Bool {
        let eventTypes: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged
        ]
        let eventMask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
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

    /// Вызывается из C-callback. Исходное событие доставляется ровно один раз,
    /// при необходимости с исправленным Unicode ожидавшей клавиши.
    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            scheduleRecovery(reason: type == .tapDisabledByTimeout ? "timeout" : "userInput")
            return Unmanaged.passUnretained(event)
        }

        if inputBuffer.intercept(type: type, event: event, at: DispatchTime.now().uptimeNanoseconds) {
            return nil
        }
        guard state != .stopped else { return Unmanaged.passUnretained(event) }

        guard let raw = correctedRawEvent(type: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }
        processingQueue.async { [handler] in handler(raw) }
        return Unmanaged.passUnretained(event)
    }

    private func scheduleRecovery(reason: String) {
        inputBuffer.cancelLease()
        DispatchQueue.main.async { [weak self] in
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
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
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.state == .running, !self.isTapAlive else { return }
                    self.logger.notice("Потерян tap после \(name.rawValue), пересоздаём")
                    self.scheduleRecovery(reason: name.rawValue)
                }
            }
            workspaceObservers.append(observer)
        }
    }

    // MARK: - Извлечение события

    /// Отделено от доставки для проверки CGEvent и снимка без отправки клавиш в UI.
    func correctedRawEvent(type: CGEventType, event: CGEvent) -> RawKeyEvent? {
        guard let original = Self.makeRawEvent(type: type, event: event) else { return nil }
        correctionLock.lock()
        let correction = queuedInputCorrection
        correctionLock.unlock()
        guard let correction else { return original }
        let corrected = correction.corrected(original)
        guard corrected.characters != original.characters else { return original }
        let units = Array(corrected.characters.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        return Self.makeRawEvent(type: type, event: event)
    }

    private static func makeRawEvent(type: CGEventType, event: CGEvent) -> RawKeyEvent? {
        let rawType: RawKeyEventType
        switch type {
        case .keyDown: rawType = .keyDown
        case .keyUp: rawType = .keyUp
        case .flagsChanged: rawType = .flagsChanged
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: rawType = .other
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
