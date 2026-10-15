import Darwin
import Foundation

/// Только запуск и pipe выполняются вне main; NSPasteboard существует лишь в
/// дочернем процессе. Ответ не печатается и не сохраняется на диск.
@MainActor
final class PasteboardCaptureProcess {
    private var process: Process?
    private var cancelled = false
    private var completed = false

    func start(
        named name: String,
        executable: URL? = Bundle.main.executableURL,
        started: @escaping PasteboardCaptureWorker.Started,
        completion: @escaping PasteboardCaptureWorker.Completion
    ) {
        guard let executable else { completion(nil); return }
        let trace = PasteboardCaptureTrace()
        trace.mark("scheduled")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let output = Pipe()
            let child = Self.makeChild(named: name, executable: executable, output: output)
            let terminated = DispatchSemaphore(value: 0)
            var launched = false
            child.terminationHandler = { _ in
                trace.mark("terminationObserved")
                terminated.signal()
            }
            do {
                trace.mark("runStarted")
                try child.run()
                launched = true
                trace.mark("runReturned")
                try? output.fileHandleForWriting.close()
                DispatchQueue.main.async {
                    self.process = child
                    if self.cancelled { self.terminate() } else { started() }
                }
                trace.mark("readStarted")
                let data = try Self.readBounded(output.fileHandleForReading)
                trace.mark("dataEOF", bytes: data.count)
                trace.mark("terminationWaitStarted")
                terminated.wait()
                trace.mark("terminationJoined")
                trace.mark("decodeStarted")
                let reply = child.terminationStatus == 0
                    ? try? JSONDecoder().decode(PasteboardCaptureReply.self, from: data) : nil
                trace.mark("decoded")
                trace.recordHelper(reply?.timing)
                DispatchQueue.main.async {
                    trace.mark("mainCompletion")
                    self.finish(reply, completion: completion)
                }
            } catch {
                trace.mark("processReadFailed")
                if launched {
                    if child.isRunning { child.terminate() }
                    terminated.wait()
                }
                DispatchQueue.main.async { self.finish(nil, completion: completion) }
            }
            try? output.fileHandleForReading.close()
        }
    }

    func cancel() {
        cancelled = true
        terminate()
    }

    private func terminate() {
        guard !completed, let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, !self.completed, let process = self.process, process.isRunning else { return }
            // Завершение ограничено одним нашим child; новый helper до его reaping не запускается.
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private func finish(_ reply: PasteboardCaptureReply?, completion: PasteboardCaptureWorker.Completion) {
        guard !completed else { return }
        completed = true
        process = nil
        completion(cancelled ? nil : reply)
    }

    nonisolated private static func makeChild(named name: String, executable: URL, output: Pipe) -> Process {
        let child = Process()
        child.executableURL = executable
        child.arguments = [PasteboardCaptureHelper.argument, name]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        return child
    }

    nonisolated private static func readBounded(_ handle: FileHandle) throws -> Data {
        var data = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            guard data.count + chunk.count <= 64 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
            data.append(chunk)
        }
        return data
    }
}
