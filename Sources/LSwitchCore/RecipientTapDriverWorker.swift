#if DEBUG
import CoreGraphics
import Foundation

/// Thread удерживает worker/state до cleanup, но не RecipientTapDriver. App-owner может запросить stop в deinit.
final class RecipientTapDriverWorker: @unchecked Sendable {
    private let state: RecipientTapDriverState
    private let target: RecoveryProcessIdentity
    private let sender: RecoveryProcessIdentity
    private let lock = NSLock()
    private let ready = DispatchGroup()
    private let finished = DispatchGroup()
    private var started = false
    private var stopping = false
    private var readySignalled = false
    private var finishedSignalled = false
    private var loop: CFRunLoop?
    private var head: CFMachPort?
    private var tail: CFMachPort?
    private var sources: [CFRunLoopSource] = []

    init(state: RecipientTapDriverState, target: RecoveryProcessIdentity, sender: RecoveryProcessIdentity) {
        self.state = state
        self.target = target
        self.sender = sender
        ready.enter()
        finished.enter()
    }

    func startAndWait() -> Bool {
        lock.lock()
        let launch = !started && !stopping
        if launch { started = true }
        let wasStopped = stopping
        lock.unlock()
        guard !wasStopped else { return false }
        if launch {
            let worker = Thread { [self] in run() }
            worker.name = "LSwitch.recipient-tap"
            worker.start()
        }
        guard ready.wait(timeout: .now() + .milliseconds(500)) == .success else {
            requestStop(.startupTimedOut)
            return false
        }
        return state.workerReady
    }

    func stopAndWait() -> Bool {
        requestStop(.stopped)
        return finished.wait(timeout: .now() + .milliseconds(250)) == .success
    }

    /// Здесь нет ожидания или post. System calls выполняются после освобождения resource lock.
    func requestStop(_ reason: RecipientTapDriverLoss) {
        lock.lock()
        stopping = true
        let hasWorker = started
        let currentLoop = loop
        lock.unlock()
        state.markLost(reason)
        if let currentLoop { CFRunLoopStop(currentLoop); CFRunLoopWakeUp(currentLoop) }
        if !hasWorker {
            state.recordCleanup()
            signalReady()
            signalFinished()
        }
    }

    /// Только вне tap callback/protected body. Быстрые consumers используют cached state.
    @discardableResult
    func refreshHealth() -> Bool {
        lock.lock()
        let ports = (head, tail)
        let active = started && !stopping
        lock.unlock()
        let identityMatches = SystemProcessIdentity.isCurrent(target) && SystemProcessIdentity.isCurrent(sender)
        let headEnabled = active && ports.0.map { CGEvent.tapIsEnabled(tap: $0) } == true
        let tailEnabled = active && ports.1.map { CGEvent.tapIsEnabled(tap: $0) } == true
        state.recordHealth(head: headEnabled, tail: tailEnabled, identityMatches: identityMatches)
        if !identityMatches { requestStop(.identityChanged) }
        return state.workerReady
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }

    private func run() {
        guard let current = CFRunLoopGetCurrent() else {
            state.markLost(.startupFailed)
            state.recordCleanup()
            signalReady()
            signalFinished()
            return
        }
        defer {
            cleanup(on: current)
            signalReady()
            signalFinished()
        }
        guard !shouldStop else { return }
        guard CGPreflightListenEventAccess() else { state.markLost(.permissionUnavailable); return }
        guard SystemProcessIdentity.isCurrent(target), SystemProcessIdentity.isCurrent(sender) else {
            state.markLost(.identityChanged)
            return
        }
        guard install(on: current), !shouldStop else {
            state.markLost(.startupFailed)
            return
        }
        state.recordInstallation(head: true, tail: true)
        guard refreshHealth() else { return }
        signalReady()
        while !shouldStop {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
            _ = refreshHealth()
        }
    }

    /// Проверенная head/tail механика probe. IPC не удерживает lock, чтобы timeout/stop не ожидал его бесконечно.
    private func install(on current: CFRunLoop) -> Bool {
        let types = [CGEventType.keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passUnretained(state).toOpaque()
        let newHead = CGEvent.tapCreateForPid(
            pid: target.processID, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: recipientDriverHeadCallback, userInfo: context
        )
        let newTail = CGEvent.tapCreateForPid(
            pid: target.processID, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: recipientDriverTailCallback, userInfo: context
        )
        let ports = [newHead, newTail].compactMap { $0 }
        let newSources = ports.compactMap { CFMachPortCreateRunLoopSource(nil, $0, 0) }
        lock.lock()
        head = newHead
        tail = newTail
        loop = current
        sources = newSources
        lock.unlock()
        guard ports.count == 2, newSources.count == 2, !shouldStop else { return false }
        for source in newSources { CFRunLoopAddSource(current, source, .defaultMode) }
        for port in ports { CGEvent.tapEnable(tap: port, enable: true) }
        return true
    }

    private func cleanup(on current: CFRunLoop) {
        state.markLost(.stopped)
        lock.lock()
        let ports = [head, tail].compactMap { $0 }
        let attached = sources
        head = nil
        tail = nil
        loop = nil
        sources = []
        lock.unlock()
        for port in ports {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        for source in attached {
            CFRunLoopRemoveSource(current, source, .defaultMode)
            CFRunLoopSourceInvalidate(source)
        }
        state.recordCleanup()
    }

    private func signalReady() {
        lock.lock()
        let signal = !readySignalled
        readySignalled = true
        lock.unlock()
        if signal { ready.leave() }
    }

    private func signalFinished() {
        lock.lock()
        let signal = !finishedSignalled
        finishedSignalled = true
        lock.unlock()
        if signal { finished.leave() }
    }
}

private func recipientDriverHeadCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let context else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<RecipientTapDriverState>.fromOpaque(context).takeUnretainedValue()
    return state.observe(type: type, event: event, isHead: true) ? Unmanaged.passUnretained(event) : nil
}

private func recipientDriverTailCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let context {
        let state = Unmanaged<RecipientTapDriverState>.fromOpaque(context).takeUnretainedValue()
        _ = state.observe(type: type, event: event, isHead: false)
    }
    return Unmanaged.passUnretained(event)
}
#endif
