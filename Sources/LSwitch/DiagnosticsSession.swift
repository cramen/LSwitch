#if DEBUG
import CryptoKit
import Darwin
import Foundation
import LSwitchCore
import os

/// Явно включаемый DEBUG-протокол. Содержит только счётчики, время и идентичность бинарника.
@MainActor
final class DiagnosticsSession {
    private struct Record: Encodable {
        let schemaVersion = 1
        let sessionID: String
        let processID: Int32
        let startedAt: Date
        let recordedAt: Date
        let wallElapsedSeconds: Double
        let reason: String
        let forcedDisableSucceeded: Bool?
        let tap: EventTapDiagnosticsSnapshot?
    }

    private let sessionID = UUID().uuidString
    private let startedAt = Date()
    private let writer: DiagnosticsJSONWriter
    private weak var tap: EventTapCore?
    private var timer: Timer?
    private var disableWorkItem: DispatchWorkItem?
    private var finished = false

    /// PATH должен быть новым абсолютным файлом; существующий протокол никогда не перезаписывается.
    static func from(arguments: [String]) throws -> DiagnosticsSession? {
        let pathPrefix = "--diagnostics-session="
        let disablePrefix = "--test-disable-tap-after="
        guard let option = arguments.first(where: { $0.hasPrefix(pathPrefix) }) else { return nil }
        let path = String(option.dropFirst(pathPrefix.count))
        guard path.hasPrefix("/"), !path.hasSuffix("/") else { throw DiagnosticsError.invalidPath }
        var disableAfter: TimeInterval?
        if let option = arguments.first(where: { $0.hasPrefix(disablePrefix) }) {
            guard let seconds = Double(option.dropFirst(disablePrefix.count)), seconds.isFinite, seconds > 0 else {
                throw DiagnosticsError.invalidDelay
            }
            disableAfter = seconds
        }
        return try DiagnosticsSession(outputURL: URL(fileURLWithPath: path), disableAfter: disableAfter)
    }

    init(outputURL: URL, interval: TimeInterval = 60, disableAfter: TimeInterval? = nil) throws {
        precondition(interval > 0)
        writer = try DiagnosticsJSONWriter(url: outputURL)
        writer.recordBinaryIdentity(url: Bundle.main.executableURL)
        sample(reason: "sessionStarted")
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample(reason: "periodic") }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        if let disableAfter { scheduleDisable(after: disableAfter) }
    }

    /// Вызывать до tap.start(), чтобы журнал включал запуск данного экземпляра.
    func attach(_ tap: EventTapCore) {
        guard !finished else { return }
        self.tap = tap
        tap.enableDiagnostics()
        sample(reason: "tapAttached")
    }

    /// Вызывать после tap.stop(), пока ссылка на экземпляр ещё доступна.
    func detach() {
        sample(reason: "tapDetached")
        tap = nil
    }

    func sample(reason: String = "manual") {
        record(reason: reason, forcedDisableSucceeded: nil)
    }

    func finish() {
        guard !finished else { return }
        sample(reason: "sessionFinished")
        finished = true
        timer?.invalidate()
        timer = nil
        disableWorkItem?.cancel()
        disableWorkItem = nil
        writer.finish()
    }

    private func scheduleDisable(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                let succeeded = self.tap?.disableTapForDiagnostics() ?? false
                self.record(reason: "forcedDisable", forcedDisableSucceeded: succeeded)
            }
        }
        disableWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func record(reason: String, forcedDisableSucceeded: Bool?) {
        guard !finished else { return }
        let now = Date()
        writer.append(Record(
            sessionID: sessionID, processID: ProcessInfo.processInfo.processIdentifier,
            startedAt: startedAt, recordedAt: now, wallElapsedSeconds: now.timeIntervalSince(startedAt),
            reason: reason, forcedDisableSucceeded: forcedDisableSucceeded, tap: tap?.diagnosticsSnapshot()
        ))
    }

    deinit {
        timer?.invalidate()
        disableWorkItem?.cancel()
        writer.finish()
    }
}

private enum DiagnosticsError: LocalizedError {
    case invalidPath, invalidDelay, cannotCreateFile

    var errorDescription: String? {
        switch self {
        case .invalidPath: return "Для диагностики требуется абсолютный путь к новому JSONL-файлу."
        case .invalidDelay: return "Задержка тестового отключения должна быть положительным числом секунд."
        case .cannotCreateFile: return "Не удалось создать новый файл диагностики; прежний файл не изменён."
        }
    }
}

/// Сериализация, хэш бинарника и I/O идут вне callback и главного run loop.
private final class DiagnosticsJSONWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lswitch.diagnostics.writer", qos: .utility)
    private let handle: FileHandle
    private let logger = Logger(subsystem: "LSwitch", category: "Diagnostics")
    private var closed = false

    init(url: URL) throws {
        let descriptor = url.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw DiagnosticsError.cannotCreateFile }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func append<Record: Encodable>(_ record: Record) {
        queue.async { [self] in write(record) }
    }

    func recordBinaryIdentity(url: URL?) {
        queue.async { [self] in
            struct Identity: Encodable {
                let reason = "binaryIdentity"
                let executableSHA256: String?
            }
            let digest = url.flatMap { try? Data(contentsOf: $0) }.map {
                SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
            }
            write(Identity(executableSHA256: digest))
        }
    }

    func finish() {
        queue.sync {
            guard !closed else { return }
            closed = true
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                logger.error("Не удалось завершить запись диагностики")
            }
        }
    }

    private func write<Record: Encodable>(_ record: Record) {
        guard !closed else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(record)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        } catch {
            logger.error("Не удалось записать снимок диагностики")
        }
    }
}
#endif
