import Dispatch
import Foundation
import os

/// Все методы backend вызываются одной фоновой очередью; completion может прийти с другой очереди.
protocol SoundFeedbackBackend: AnyObject {
    func prepare() -> Bool
    func play(completion: @escaping @Sendable () -> Void)
    func dispose()
}

/// Main никогда не вызывает аудио API и не ждёт worker; OFF отзывает ожидающие запросы.
public final class SoundFeedbackController: @unchecked Sendable {
    private let worker: SoundFeedbackWorker

    public convenience init() {
        self.init(backendFactory: { SystemSoundFeedbackBackend() })
    }

    init(backendFactory: @escaping () -> any SoundFeedbackBackend) {
        worker = SoundFeedbackWorker(backendFactory: backendFactory)
    }

    deinit { worker.shutdown() }

    /// Включение также заранее подготавливает ресурс, не проигрывая звук.
    public func setEnabled(_ enabled: Bool) { worker.setEnabled(enabled) }

    public func prepare() { worker.prepare() }

    /// Подключается только к существующему onConverted, который не вызывается для undo/partial.
    public func conversionSucceeded() { worker.requestPlay() }

    public func handle(_ outcome: Converter.Outcome) {
        guard case .converted = outcome else { return }
        conversionSucceeded()
    }

    public func shutdown() { worker.shutdown() }

    /// Барьер очереди для тестов; не ждёт физического окончания асинхронного аудио.
    func drainScheduledWork() async { await worker.drainScheduledWork() }
}

private final class SoundFeedbackWorker: @unchecked Sendable {
    private struct Control {
        var enabled = false
        var closed = false
        var generation: UInt64 = 0
    }

    private let lock = NSLock()
    private var control = Control()
    private let queue = DispatchQueue(label: "lswitch.sound-feedback", qos: .utility)
    private let factory: () -> any SoundFeedbackBackend
    private let logger = Logger(subsystem: "LSwitch", category: "Sound")
    // Следующие поля принадлежат только queue; аудио API никогда не вызывается под lock.
    private var backend: (any SoundFeedbackBackend)?
    private var prepared = false
    private var activePlays = 0

    init(backendFactory: @escaping () -> any SoundFeedbackBackend) { factory = backendFactory }

    private var state: Control {
        lock.lock()
        defer { lock.unlock() }
        return control
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        guard !control.closed else {
            lock.unlock()
            return
        }
        if control.enabled != enabled {
            control.enabled = enabled
            control.generation &+= 1
        }
        lock.unlock()
        prepare()
    }

    func prepare() {
        queue.async {
            let state = self.state
            guard state.enabled, !state.closed else {
                self.disposeIfIdle()
                return
            }
            _ = self.prepareIfNeeded()
        }
    }

    func requestPlay() {
        let requested = state
        guard requested.enabled, !requested.closed else { return }
        queue.async {
            guard self.isCurrent(requested.generation), self.prepareIfNeeded(),
                  self.isCurrent(requested.generation), let backend = self.backend else { return }
            self.activePlays += 1
            let started = DispatchTime.now().uptimeNanoseconds
            self.logger.info("audio.play.begin main=\(Thread.isMainThread, privacy: .public)")
            backend.play {
                self.queue.async {
                    self.activePlays -= 1
                    self.logger.info("audio.play.attempt-finished")
                    self.disposeIfIdle()
                }
            }
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            self.logger.info("audio.play.return elapsedMs=\(elapsed, privacy: .public)")
        }
    }

    func shutdown() {
        lock.lock()
        guard !control.closed else {
            lock.unlock()
            return
        }
        control.closed = true
        control.enabled = false
        control.generation &+= 1
        lock.unlock()
        queue.async { self.disposeIfIdle() }
    }

    func drainScheduledWork() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        let current = state
        return current.enabled && !current.closed && current.generation == generation
    }

    private func prepareIfNeeded() -> Bool {
        if prepared { return true }
        if backend == nil { backend = factory() }
        let started = DispatchTime.now().uptimeNanoseconds
        logger.info("audio.prepare.begin main=\(Thread.isMainThread, privacy: .public)")
        prepared = backend?.prepare() == true
        let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let ready = prepared
        logger.info("audio.prepare.return elapsedMs=\(elapsed, privacy: .public) ready=\(ready, privacy: .public)")
        let current = state
        guard current.enabled, !current.closed else {
            disposeIfIdle()
            return false
        }
        return prepared
    }

    private func disposeIfIdle() {
        let current = state
        guard activePlays == 0, current.closed || !current.enabled else { return }
        backend?.dispose()
        backend = nil
        prepared = false
    }
}
