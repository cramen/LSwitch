#if DEBUG
import Foundation

/// Отдельная от Main очередь страхует только один собственный child diagnostic Enable.
final class RecoveryIsolationSecureWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var ended = false
    private var fired = false

    func arm(
        action: @escaping @Sendable () -> Void,
        schedule: (@escaping @Sendable () -> Void) -> Void = { action in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(4), execute: action)
        }
    ) -> Bool {
        lock.lock()
        guard !armed, !ended else { lock.unlock(); return false }
        armed = true
        lock.unlock()
        schedule { [self] in
            lock.lock()
            guard armed, !ended else { lock.unlock(); return }
            ended = true
            fired = true
            lock.unlock()
            action()
        }
        return true
    }

    func cancel() { lock.lock(); ended = true; lock.unlock() }
    var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
}
#endif
