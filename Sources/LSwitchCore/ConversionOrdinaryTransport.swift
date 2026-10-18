import Foundation

enum ConversionOrdinaryAcceptance {
    case refused
    case accepted(ConversionOrdinaryTransport)
}

enum ConversionOrdinaryTransportResult: Equatable, Sendable {
    case locallyDispatched
    case retainedFailure
}

/// Метаданные локального transport, без очереди, post и обещания renderer ACK.
/// Provider сохраняет владение данными до терминального результата даже при отмене ожидания.
final class ConversionOrdinaryTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal: ConversionOrdinaryTransportResult?
    private var waiter: CheckedContinuation<ConversionOrdinaryTransportResult?, Never>?
    private var waitingStarted = false
    private var retention = false
    private let onRetentionRequested: @Sendable () -> Void

    init(onRetentionRequested: @escaping @Sendable () -> Void = {}) {
        self.onRetentionRequested = onRetentionRequested
    }

    var retentionRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return retention
    }

    func requestRetention() {
        lock.lock()
        let notify = terminal == nil && !retention
        if notify { retention = true }
        lock.unlock()
        if notify { onRetentionRequested() }
    }

    /// Вызывается только после локального quiescence: повторное завершение ничего не меняет.
    @discardableResult
    func complete(_ result: ConversionOrdinaryTransportResult) -> Bool {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return false }
        terminal = result
        let continuation = waiter
        waiter = nil
        lock.unlock()
        continuation?.resume(returning: result)
        return true
    }

    func waitForTerminal() async -> ConversionOrdinaryTransportResult? {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in register(continuation) }
        }, onCancel: { self.requestRetention() })
    }

    private func register(_ continuation: CheckedContinuation<ConversionOrdinaryTransportResult?, Never>) {
        lock.lock()
        guard !waitingStarted else { lock.unlock(); continuation.resume(returning: nil); return }
        waitingStarted = true
        if let terminal {
            lock.unlock()
            continuation.resume(returning: terminal)
        } else {
            waiter = continuation
            lock.unlock()
        }
    }
}
