#if DEBUG
import CoreGraphics
import Foundation

/// Изолированный own-PID gate пробника. Не используется как production admission.
final class RecoveryReceiverProbeGate: @unchecked Sendable {
    struct Snapshot {
        let admitted: [String]
        let blocked: [String]
        let tail: [String]
        let headEnabled: Bool
        let tailEnabled: Bool
        let failure: String?
        let cleanupCompleted: Bool
        let disableNotifications: Int
        let balancedUpCount: Int
    }

    let markerBase = Int64.random(in: 1..<(Int64.max - 2))
    private let processID = getpid()
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private let admissionBarrier = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let tailPairObserved = DispatchSemaphore(value: 0)
    private let allowsPairedUpAfterClose: Bool
    private var headTap: CFMachPort?
    private var tailTap: CFMachPort?
    private var generationClosed = false
    private var stopping = false
    private var cleaned = false
    private var admitted: [String] = []
    private var blocked: [String] = []
    private var tail: [String] = []
    private var failure: String?
    private var disableNotifications = 0
    private var balancedUpCount = 0

    init(allowsPairedUpAfterClose: Bool = false) {
        self.allowsPairedUpAfterClose = allowsPairedUpAfterClose
    }

    /// До releaseAdmissions worker не обслуживает callbacks: можно закрыть уже отправленное поколение.
    func start() -> Bool {
        let worker = Thread { [self] in threadMain() }
        worker.name = "LSwitch.recovery-receiver-probe"
        worker.start()
        guard ready.wait(timeout: .now() + .milliseconds(500)) == .success else { return false }
        let state = snapshot()
        return state.failure == nil && state.headEnabled && state.tailEnabled
    }

    func closeGeneration() {
        lock.lock()
        generationClosed = true
        lock.unlock()
    }

    func releaseAdmissions() { admissionBarrier.signal() }

    /// Main не обслуживает AppKit во время этого ожидания; callback только сигнализирует tail.
    func waitForTailPair() -> Bool {
        tailPairObserved.wait(timeout: .now() + .milliseconds(100)) == .success
    }

    func disableHead() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let headTap, !stopping else { return false }
        CGEvent.tapEnable(tap: headTap, enable: false)
        return !CGEvent.tapIsEnabled(tap: headTap)
    }

    /// Ограниченное ожидание; worker удерживает себя до очистки даже при неуспехе join.
    func stop() -> Bool {
        lock.lock()
        stopping = true
        lock.unlock()
        admissionBarrier.signal()
        return finished.wait(timeout: .now() + .milliseconds(250)) == .success
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            admitted: admitted, blocked: blocked, tail: tail,
            headEnabled: headTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
            tailEnabled: tailTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
            failure: failure, cleanupCompleted: cleaned, disableNotifications: disableNotifications,
            balancedUpCount: balancedUpCount
        )
    }

    func eventLabel(_ event: CGEvent) -> String? {
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if marker == markerBase, event.type == .keyDown { return "down" }
        if marker == markerBase + 1, event.type == .keyUp { return "up" }
        return nil
    }

    fileprivate func observe(type: CGEventType, event: CGEvent, isHead: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            disableNotifications += 1
            return true
        }
        // Не извлекаем keycode, Unicode или flags неизвестных событий.
        guard let label = eventLabel(event) else { return true }
        if admitted.count + blocked.count + tail.count >= 16 {
            failure = "observation_limit"
            return !isHead
        }
        if isHead {
            return admitHeadLocked(label)
        }
        tail.append(label)
        if tail == ["down", "up"] { tailPairObserved.signal() }
        return true
    }

    /// Вызывается только под lock. Исключение относится к единственной собственной паре этого probe.
    private func admitHeadLocked(_ label: String) -> Bool {
        let balancing = generationClosed && allowsPairedUpAfterClose && label == "up"
            && admitted.contains("down") && !admitted.contains("up")
        if stopping || (generationClosed && !balancing) {
            blocked.append(label)
            return false
        }
        admitted.append(label)
        if balancing { balancedUpCount += 1 }
        return true
    }

    private func threadMain() {
        let deadline = DispatchTime.now().uptimeNanoseconds + 4_500_000_000
        guard let runLoop = CFRunLoopGetCurrent() else {
            lock.lock()
            failure = "worker_run_loop"
            cleaned = true
            lock.unlock()
            ready.signal()
            finished.signal()
            return
        }
        var sources: [CFRunLoopSource] = []
        defer {
            lock.lock()
            for tap in [headTap, tailTap].compactMap({ $0 }) {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            headTap = nil
            tailTap = nil
            for source in sources {
                CFRunLoopRemoveSource(runLoop, source, .defaultMode)
                CFRunLoopSourceInvalidate(source)
            }
            cleaned = true
            lock.unlock()
            finished.signal()
        }
        guard install(runLoop: runLoop, sources: &sources) else {
            ready.signal()
            return
        }
        ready.signal()
        guard admissionBarrier.wait(timeout: .now() + .seconds(4)) == .success else { return }
        while DispatchTime.now().uptimeNanoseconds < deadline {
            lock.lock()
            let shouldStop = stopping
            lock.unlock()
            if shouldStop { break }
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
        }
    }

    private func install(runLoop: CFRunLoop, sources: inout [CFRunLoopSource]) -> Bool {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        lock.lock()
        defer { lock.unlock() }
        headTap = CGEvent.tapCreateForPid(
            pid: processID, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: recoveryReceiverHeadCallback, userInfo: context
        )
        tailTap = CGEvent.tapCreateForPid(
            pid: processID, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: recoveryReceiverTailCallback, userInfo: context
        )
        guard let headTap, let tailTap else {
            failure = "tap_create"
            return false
        }
        for tap in [headTap, tailTap] {
            guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
                failure = "run_loop_source"
                return false
            }
            sources.append(source)
            CFRunLoopAddSource(runLoop, source, .defaultMode)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return true
    }
}

private func recoveryReceiverHeadCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let context else { return Unmanaged.passUnretained(event) }
    let gate = Unmanaged<RecoveryReceiverProbeGate>.fromOpaque(context).takeUnretainedValue()
    return gate.observe(type: type, event: event, isHead: true) ? Unmanaged.passUnretained(event) : nil
}

private func recoveryReceiverTailCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, context: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let context {
        let gate = Unmanaged<RecoveryReceiverProbeGate>.fromOpaque(context).takeUnretainedValue()
        _ = gate.observe(type: type, event: event, isHead: false)
    }
    return Unmanaged.passUnretained(event)
}
#endif
