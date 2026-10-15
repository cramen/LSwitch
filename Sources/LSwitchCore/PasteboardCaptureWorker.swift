import Foundation

/// По завершении helper возвращает только неизменяемые данные и версию clipboard.
struct PasteboardCaptureReply: Codable, Sendable {
    let snapshot: PasteboardSnapshot
    let changeCountBefore: Int
    let changeCountAfter: Int
    let timing: PasteboardHelperTiming?

    init(
        snapshot: PasteboardSnapshot, changeCountBefore: Int, changeCountAfter: Int,
        timing: PasteboardHelperTiming? = nil
    ) {
        self.snapshot = snapshot
        self.changeCountBefore = changeCountBefore
        self.changeCountAfter = changeCountAfter
        self.timing = timing
    }
}

enum PasteboardCaptureResult: Equatable, Sendable {
    case captured(PasteboardSnapshot, changeCount: Int)
    case timedOut, cancelled, busy, unavailable, changed
}

/// Deadline завершает ожидание независимо от системного read. Пока helper не
/// завершился, следующая операция отказывает: зависшие процессы не накапливаются.
@MainActor
final class PasteboardCaptureWorker {
    typealias Completion = @MainActor @Sendable (PasteboardCaptureReply?) -> Void
    typealias Started = @MainActor @Sendable () -> Void
    typealias Start = (String, @escaping Started, @escaping Completion) -> (() -> Void)

    typealias Launch = (URL, String, @escaping Started, @escaping Completion) -> (() -> Void)

    static let shared = configured(capability: ClipboardCaptureSupport.capability) { url, name, started, completion in
        let process = PasteboardCaptureProcess()
        process.start(named: name, executable: url, started: started, completion: completion)
        return { process.cancel() }
    }

    static func configured(capability: ClipboardHelperCapability, launch: @escaping Launch) -> PasteboardCaptureWorker {
        PasteboardCaptureWorker(isAvailable: { capability.executableURL != nil }, start: { name, started, completion in
            guard let executable = capability.executableURL else { completion(nil); return {} }
            return launch(executable, name, started, completion)
        })
    }

    @MainActor
    private final class Pending {
        var continuation: CheckedContinuation<PasteboardCaptureResult, Never>?
        var cancel: () -> Void = {}
        var diagnostics: ConversionDiagnostics?
    }

    private let start: Start
    private let isAvailable: () -> Bool
    private let timeout: TimeInterval
    private var pending: Pending?

    init(timeout: TimeInterval = 0.1, isAvailable: @escaping () -> Bool = { true }, start: @escaping Start) {
        self.timeout = timeout
        self.isAvailable = isAvailable
        self.start = start
    }

    func capture(named name: String, diagnostics: ConversionDiagnostics? = nil) async -> PasteboardCaptureResult {
        guard isAvailable() else { return .unavailable }
        guard pending == nil else { return .busy }
        guard !Task.isCancelled else { return .cancelled }
        let operation = Pending()
        operation.diagnostics = diagnostics
        pending = operation
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                operation.continuation = continuation
                diagnostics?.mark(.captureHelperLaunchStarted)
                operation.cancel = start(name, { [weak self] in
                    guard self?.pending === operation, operation.continuation != nil else { return }
                    diagnostics?.mark(.captureHelperLaunched)
                }, { [weak self] reply in
                    self?.completed(operation, reply: reply)
                })
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.abort(operation, result: .timedOut)
                }
            }
        }, onCancel: { [self] in
            Task { @MainActor [self] in abort(operation, result: .cancelled) }
        })
    }

    private func abort(_ operation: Pending, result: PasteboardCaptureResult) {
        guard pending === operation, let continuation = operation.continuation else { return }
        operation.continuation = nil
        operation.diagnostics = nil
        operation.cancel()
        continuation.resume(returning: result)
    }

    private func completed(_ operation: Pending, reply: PasteboardCaptureReply?) {
        guard pending === operation else { return }
        pending = nil
        guard let continuation = operation.continuation else { return }
        operation.continuation = nil
        operation.diagnostics?.mark(.captureHelperReturned)
        let result: PasteboardCaptureResult
        if let reply {
            result = reply.changeCountBefore == reply.changeCountAfter
                ? .captured(reply.snapshot, changeCount: reply.changeCountAfter) : .changed
        } else {
            result = .unavailable
        }
        continuation.resume(returning: result)
    }
}
