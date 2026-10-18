#if DEBUG
import Darwin
import Foundation

/// Запускает только собственный signed executable. Inherited pipes несут ограниченные metadata frames.
@MainActor
final class RecoveryIsolationChildProcess {
    let nonce = UUID().uuidString
    private let process = Process()
    private var input: FileHandle?
    private var mailbox: RecoveryIsolationChildMailbox?
    private let writer = DispatchQueue(label: "LSwitch.isolation-parent.writer")
    private var sequence = 0
    private var started = false
    private let secureWatchdog = RecoveryIsolationSecureWatchdog()

    var processID: Int32 { started ? process.processIdentifier : 0 }
    var isRunning: Bool { started && process.isRunning }
    var exitStatus: Int32? { started && !process.isRunning ? process.terminationStatus : nil }

    func start(matrixHelper: Bool = false) -> Bool {
        guard !started, let mainExecutable = Bundle.main.executableURL,
              Bundle.main.bundleIdentifier == "ru.cramen.lswitch" else { return false }
        let executable = matrixHelper ? Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Helpers/LSwitch Event Receiver.app/Contents/MacOS/LSwitchReceiver"
        ) : mainExecutable
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        let commandPipe = Pipe()
        let responsePipe = Pipe()
        let errorPipe = Pipe()
        let descriptor = commandPipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) >= 0 else { return false }
        process.executableURL = executable
        process.arguments = ["--recovery-isolation-receiver", "--isolation-nonce=\(nonce)",
                             "--isolation-sender-pid=\(getpid())"]
        process.standardInput = commandPipe
        process.standardOutput = responsePipe
        process.standardError = errorPipe
        do { try process.run() } catch { return false }
        started = true
        input = commandPipe.fileHandleForWriting
        let mailbox = RecoveryIsolationChildMailbox(nonce: nonce, sender: getpid(), target: process.processIdentifier)
        self.mailbox = mailbox
        process.terminationHandler = { child in mailbox.recordExit(child.terminationStatus) }
        try? commandPipe.fileHandleForReading.close()
        try? responsePipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        Self.readResponses(responsePipe.fileHandleForReading, mailbox: mailbox)
        Self.readErrors(errorPipe.fileHandleForReading, mailbox: mailbox)
        return true
    }

    /// Возвращает номер отправленной команды; нет команд с произвольным текстом или путём.
    func send(_ command: RecoveryIsolationCommand, markers: [RecoveryIsolationLabel: Int64]? = nil) -> Int? {
        guard isRunning, sequence < RecoveryIsolationWire.maximumRequests, let input, let mailbox else { return nil }
        let next = sequence + 1
        var fields: [String: Any] = ["v": 1, "nonce": nonce, "sequence": next, "command": command.rawValue]
        if let markers {
            fields["markers"] = Dictionary(uniqueKeysWithValues: markers.map { ($0.key.rawValue, $0.value) })
        }
        guard let data = RecoveryIsolationWire.encode(fields),
              data.count <= RecoveryIsolationWire.maximumRequestBytes,
              RecoveryIsolationWire.decode(Data(data.dropLast()), nonce: nonce, expectedSequence: next) != nil else {
            return nil
        }
        sequence = next
        writer.async {
            if !Self.write(data, descriptor: input.fileDescriptor) { mailbox.recordFailure("child_write") }
        }
        return next
    }

    /// Только этот уже запущенный Foundation Process; действие не зависит от main run loop.
    func armSecureWatchdog() -> Bool {
        guard isRunning else { return false }
        let process = self.process
        return secureWatchdog.arm(action: {
            if process.isRunning { process.terminate() }
        })
    }

    func cancelSecureWatchdog() { secureWatchdog.cancel() }
    var secureWatchdogFired: Bool { secureWatchdog.didFire }

    func take() -> IsolationChildMailboxSnapshot? { mailbox?.take() }

    func closeInput() {
        guard let input else { return }
        self.input = nil
        writer.async { try? input.close() }
    }

    /// Только собственный Process после ограниченного graceful ожидания. Не обращается к чужим PID.
    func terminateIfRunning() {
        closeInput()
        if isRunning { process.terminate() }
    }

    /// Последний bounded cleanup только собственного пустого fixture-процесса после отказа SIGTERM.
    func forceTerminateIfRunning() {
        closeInput()
        if isRunning, processID > 0 { _ = Darwin.kill(processID, SIGKILL) }
    }

    private nonisolated static func readResponses(_ handle: FileHandle, mailbox: RecoveryIsolationChildMailbox) {
        Thread {
            defer { try? handle.close(); mailbox.recordEOF() }
            readChunks(handle.fileDescriptor, consume: { mailbox.ingest($0) }, failed: {
                mailbox.recordFailure("child_read")
            })
        }.start()
    }

    private nonisolated static func readErrors(_ handle: FileHandle, mailbox: RecoveryIsolationChildMailbox) {
        Thread {
            defer { try? handle.close() }
            readChunks(handle.fileDescriptor, consume: { mailbox.recordStderr(bytes: $0.count) }, failed: {
                mailbox.recordFailure("child_stderr_read")
            })
        }.start()
    }

    /// POSIX read возвращает доступный короткий frame; не ждёт накопления запрошенных 1024 байт.
    private nonisolated static func readChunks(
        _ descriptor: Int32, consume: (Data) -> Void, failed: () -> Void
    ) {
        var bytes = [UInt8](repeating: 0, count: RecoveryIsolationWire.maximumReplyBytes)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 { consume(Data(bytes.prefix(count))); continue }
            if count == 0 { return }
            if errno != EINTR { failed(); return }
        }
    }

    private nonisolated static func write(_ data: Data, descriptor: Int32) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 100_000_000
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count, DispatchTime.now().uptimeNanoseconds < deadline {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                var descriptorState = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = Darwin.poll(&descriptorState, 1, 10)
            }
            return offset == bytes.count
        }
    }
}
#endif
