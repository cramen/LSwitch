#if DEBUG
import Foundation

public enum RecipientDiagnosticTap: String, Sendable { case head, tail }

/// Одноразовое завершение diagnostic request. Timeout не означает, что системный tap уже отключён.
final class RecipientDiagnosticDisableReply: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = true
    private var started = false
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pending, !started else { return false }
        started = true
        return true
    }

    func finish(_ disabled: Bool) {
        lock.lock()
        guard pending else { lock.unlock(); return }
        pending = false
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: disabled)
    }
}
#endif
