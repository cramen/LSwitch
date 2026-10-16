#if DEBUG
import Darwin
import Foundation

/// Inherited pipe endpoints. Все mutable поля ниже принадлежат serial queue; callbacks не получают raw JSON.
final class RecoveryIsolationPipe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LSwitch.isolation-receiver.pipe")
    private let nonce: String
    private let onRequest: @Sendable (RecoveryIsolationRequest) -> Void
    private let onEnd: @Sendable (String) -> Void
    private var source: DispatchSourceRead?
    private var frame: [UInt8] = []
    private var requestCount = 0
    private var replyCount = 0
    private var acceptingInput = true
    private var writeFailed = false
    private var outputClosed = false

    init(
        nonce: String, onRequest: @escaping @Sendable (RecoveryIsolationRequest) -> Void,
        onEnd: @escaping @Sendable (String) -> Void
    ) {
        self.nonce = nonce
        self.onRequest = onRequest
        self.onEnd = onEnd
    }

    /// Вызывается до публикации source. Терминалы, файлы и sockets не принимаются вместо inherited pipes.
    func start() -> Bool {
        guard Self.isPipe(STDIN_FILENO), Self.isPipe(STDOUT_FILENO),
              Self.makeNonblocking(STDIN_FILENO), Self.makeNonblocking(STDOUT_FILENO) else { return false }
        // Только этот отдельный child: закрытие stdout родителем не должно обходить cleanup через SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        self.source = source
        source.resume()
        return true
    }

    @discardableResult
    func send(_ fields: [String: Any]) -> Bool {
        guard let data = RecoveryIsolationWire.encode(fields) else { return false }
        queue.async { [self] in
            guard !outputClosed, !writeFailed else { return }
            guard replyCount < RecoveryIsolationWire.maximumReplies else { return failOutput() }
            replyCount += 1
            if !writeFrame(data) { failOutput() }
        }
        return true
    }

    func stopInput() { queue.async { [self] in cancelInput() } }

    /// Main вызывает после остановки AppKit. Один write ограничен 100 мс; после первой ошибки новые skip.
    func closeAfterDraining() -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            cancelInput()
            outputClosed = true
            Darwin.close(STDIN_FILENO)
            Darwin.close(STDOUT_FILENO)
            done.signal()
        }
        guard done.wait(timeout: .now() + .milliseconds(250)) == .success else { return false }
        // Semaphore публикует итог serial queue. После outputClosed новые send не меняют writeFailed.
        return !writeFailed
    }

    private func readAvailable() {
        guard acceptingInput else { return }
        var bytes = [UInt8](repeating: 0, count: RecoveryIsolationWire.maximumRequestBytes)
        let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        if count == 0 { return endInput(frame.isEmpty ? "eof" : "protocol") }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            return endInput("protocol")
        }
        for byte in bytes.prefix(count) {
            if byte == 10 {
                guard requestCount < RecoveryIsolationWire.maximumRequests,
                      let request = RecoveryIsolationWire.decode(
                        Data(frame), nonce: nonce, expectedSequence: requestCount + 1
                      ) else { return endInput("protocol") }
                frame.removeAll(keepingCapacity: true)
                requestCount += 1
                onRequest(request)
            } else {
                guard frame.count < RecoveryIsolationWire.maximumRequestBytes - 1 else {
                    return endInput("protocol")
                }
                frame.append(byte)
            }
        }
    }

    private func endInput(_ reason: String) {
        cancelInput()
        onEnd(reason)
    }

    private func cancelInput() {
        acceptingInput = false
        source?.cancel()
        source = nil
        frame.removeAll(keepingCapacity: false)
    }

    private func failOutput() {
        guard !writeFailed else { return }
        writeFailed = true
        endInput("protocol")
    }

    private func writeFrame(_ data: Data) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count, DispatchTime.now().uptimeNanoseconds < deadline {
                let written = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                var descriptor = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&descriptor, 1, 10)
            }
            return offset == bytes.count
        }
    }

    private static func isPipe(_ descriptor: Int32) -> Bool {
        var information = stat()
        return fstat(descriptor, &information) == 0
            && (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFIFO)
    }

    private static func makeNonblocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0
    }
}
#endif
