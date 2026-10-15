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
    private let processingQueue: DispatchQueue
    private let logger = Logger(subsystem: "LSwitch", category: "EventTap")
    private let correctionLock = NSLock()
    private var queuedInputCorrection: QueuedInputCorrection?
    private let inputBuffer = InputEventBuffer()

    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var healthTimer: Timer?
    private var lifecycleGeneration: UInt64 = 0
    #if DEBUG
    private var diagnosticsMetrics: EventTapMetrics?
    #endif
    /// Сколько раз tap пересоздавался с момента запуска (диагностика спайка).
    public private(set) var recoveryCount = 0

    public private(set) var state: State = .stopped
    @MainActor public var onRecoveryStarted: (UInt64) -> Void = { _ in }
    @MainActor private var deliveryGate = EventDeliveryGate()

    /// - Parameter handler: вызывается на выделенной последовательной очереди
    ///   для каждого перехваченного события (включая синтетику — фильтрация
    ///   на стороне подписчика через `RawKeyEvent.isSynthetic`).
    public convenience init(handler: @escaping Handler) {
        self.init(handler: handler, processingQueue: DispatchQueue(label: "lswitch.eventtap.processing"))
    }

    init(handler: @escaping Handler, processingQueue: DispatchQueue) {
        self.handler = handler
        self.processingQueue = processingQueue
    }

    /// После hold пропускает захваченные ранее raw-события через обе очереди потребителя.
    @MainActor
    public func drainPendingEvents() async {
        await withCheckedContinuation { continuation in
            processingQueue.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    public var isInputHeld: Bool { inputBuffer.isHolding }

    @MainActor
    public func beginInputHold() -> Bool {
        guard state == .running,
              let generation = inputBuffer.begin(at: DispatchTime.now().uptimeNanoseconds) else {
            #if DEBUG
            diagnosticsMetrics?.increment(.holdRefusals)
            #endif
            return false
        }
        #if DEBUG
        diagnosticsMetrics?.increment(.holdGrants)
        #endif
        processingQueue.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            guard let self else { return }
            self.inputBuffer.expire(generation: generation, at: DispatchTime.now().uptimeNanoseconds)
            #if DEBUG
            if !self.inputBuffer.isHolding { self.diagnosticsMetrics?.invalidateHold() }
            #endif
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
        #if DEBUG
        diagnosticsMetrics?.finishHold(released: delivered)
        #endif
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
        healthTimer?.invalidate()
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
        lifecycleGeneration &+= 1
        #if DEBUG
        diagnosticsMetrics?.increment(.starts)
        #endif
        subscribeWorkspaceNotifications()
        startHealthChecks()
        logger.info("Event tap запущен")
        return true
    }

    @MainActor
    public func stop() {
        #if DEBUG
        if state != .stopped { diagnosticsMetrics?.increment(.stops) }
        diagnosticsMetrics?.invalidateHold()
        #endif
        state = .stopped
        lifecycleGeneration &+= 1
        healthTimer?.invalidate()
        healthTimer = nil
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
}

extension EventTapCore {
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
    func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        #if DEBUG
        let measuredAt = diagnosticsMetrics.map { _ in DispatchTime.now().uptimeNanoseconds }
        defer {
            if let measuredAt { diagnosticsMetrics?.recordCallback(startedAt: measuredAt) }
        }
        #endif
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            #if DEBUG
            let notification: EventTapMetrics.Counter = type == .tapDisabledByTimeout
                ? .timeoutNotifications : .userDisableNotifications
            diagnosticsMetrics?.increment(notification)
            #endif
            scheduleRecovery(reason: type == .tapDisabledByTimeout ? "timeout" : "userInput")
            return Unmanaged.passUnretained(event)
        }

        if inputBuffer.intercept(type: type, event: event, at: DispatchTime.now().uptimeNanoseconds) {
            #if DEBUG
            diagnosticsMetrics?.increment(.heldEvents)
            if !inputBuffer.isHolding { diagnosticsMetrics?.invalidateHold() }
            #endif
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
        #if DEBUG
        diagnosticsMetrics?.invalidateHold()
        #endif
        let generation = lifecycleGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.state != .stopped, self.lifecycleGeneration == generation else { return }
            let startsRecovery = self.state != .recovering
            self.state = .recovering
            if startsRecovery { self.invalidateProcessingContextForRecovery(at: DispatchTime.now().uptimeNanoseconds) }
            guard self.state == .recovering, self.lifecycleGeneration == generation else { return }
            self.recoveryCount += 1
            #if DEBUG
            self.diagnosticsMetrics?.increment(.recoveryAttempts)
            #endif
            self.logger.notice("Event tap отключён системой (\(reason)), пересоздаём (#\(self.recoveryCount))")
            if let port = self.machPort {
                // Быстрый путь: просто включить обратно.
                CGEvent.tapEnable(tap: port, enable: true)
            }
            if self.machPort == nil || !self.isTapAlive {
                self.teardownTapOnly()
                if !self.createTap() {
                    #if DEBUG
                    self.diagnosticsMetrics?.increment(.recoveryFailures)
                    #endif
                    self.logger.error("Пересоздание tap не удалось, повтор через 1 с")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, self.lifecycleGeneration == generation else { return }
                        self.scheduleRecovery(reason: "retry")
                    }
                    return
                }
            }
            self.state = .running
            #if DEBUG
            self.diagnosticsMetrics?.increment(.recoverySuccesses)
            #endif
        }
    }

    /// Явный tapEnable(false) может не прислать disabled callback. Проверка не зависит от ввода.
    private func startHealthChecks() {
        healthTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.state == .running, !self.isTapAlive else { return }
            #if DEBUG
            self.diagnosticsMetrics?.increment(.silentDisableDetections)
            #endif
            self.scheduleRecovery(reason: "healthCheck")
        }
        healthTimer = timer
        RunLoop.main.add(timer, forMode: .common)
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
                    guard let self else { return }
                    #if DEBUG
                    self.diagnosticsMetrics?.increment(
                        name == NSWorkspace.didWakeNotification ? .wakeNotifications : .sessionNotifications
                    )
                    #endif
                    guard self.state == .running, !self.isTapAlive else { return }
                    self.logger.notice("Потерян tap после \(name.rawValue), пересоздаём")
                    self.scheduleRecovery(reason: name.rawValue)
                }
            }
            workspaceObservers.append(observer)
        }
    }

    #if DEBUG
    /// Включается только явной диагностической сессией. Без неё callback не измеряет время.
    @MainActor
    public func enableDiagnostics() { if diagnosticsMetrics == nil { diagnosticsMetrics = EventTapMetrics() } }

    @MainActor
    public func diagnosticsSnapshot() -> EventTapDiagnosticsSnapshot? {
        diagnosticsMetrics?.snapshot(
            state: String(describing: state), tapEnabled: isTapAlive, now: DispatchTime.now().uptimeNanoseconds
        )
    }

    /// Настоящее отключение; восстановление выполняет обычный health-check, а не этот метод.
    @MainActor
    @discardableResult
    public func disableTapForDiagnostics() -> Bool {
        guard diagnosticsMetrics != nil, state == .running, let machPort, isTapAlive else { return false }
        CGEvent.tapEnable(tap: machPort, enable: false)
        let disabled = !CGEvent.tapIsEnabled(tap: machPort)
        if disabled { diagnosticsMetrics?.increment(.forcedDisables) }
        return disabled
    }
    #endif

    /// Проверяется потребителем на main непосредственно перед обработкой, а не до async-перехода.
    @MainActor
    public func acceptsForProcessing(_ event: RawKeyEvent) -> Bool { deliveryGate.accepts(timestamp: event.timestamp) }

    @MainActor
    func invalidateProcessingContextForRecovery(at timestamp: UInt64) {
        deliveryGate.reset(at: timestamp)
        onRecoveryStarted(deliveryGate.cutoff)
    }

    var currentInputCorrection: QueuedInputCorrection? {
        correctionLock.lock()
        defer { correctionLock.unlock() }
        return queuedInputCorrection
    }
}
