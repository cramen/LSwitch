#if DEBUG
import Foundation

enum RecoverySystemFaultContinuationResult: Equatable { case completed, stopped, refused }

/// Этот latch закрывается до await retention и не открывается после отменённого Quit.
/// Он не относится к cleanup: balancing Up и сохранение prefix используют отдельные границы.
@MainActor
final class RecoverySystemFaultContinuation {
    private(set) var isOpen = true

    func stop() { isOpen = false }

    func after(
        _ operation: () async -> Bool, then continuation: () async -> Void
    ) async -> RecoverySystemFaultContinuationResult {
        guard isOpen else { return .stopped }
        let accepted = await operation()
        guard isOpen else { return .stopped }
        guard accepted else { return .refused }
        await continuation()
        return isOpen ? .completed : .stopped
    }

    @discardableResult
    func ifCurrent(after action: () -> Void, then continuation: () -> Void) -> Bool {
        guard isOpen else { return false }
        action()
        guard isOpen else { return false }
        continuation()
        return true
    }

    /// Применяется к watchdog→Enable: никакого send до успешно принятой страховки.
    func prepareThenSend(prepare: () -> Bool, send: () -> Bool) -> Bool {
        guard isOpen, prepare(), isOpen else { return false }
        return send()
    }
}
#endif
