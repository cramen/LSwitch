import Dispatch
import Foundation
import os

/// Тайминги helper возвращаются вместе со снимком только через RAM pipe.
struct PasteboardHelperTiming: Codable, Equatable, Sendable {
    let mainEntered: UInt64
    let boardOpened: UInt64
    let captureFinished: UInt64
    let encodingStarted: UInt64
}

/// Фиксирует время на фактической очереди, без дополнительного MainActor hop.
struct PasteboardCaptureTrace: Sendable {
    private let logger = Logger(subsystem: "LSwitch", category: "ClipboardCapture")
    private let identifier = UUID().uuidString
    private let startedAt = DispatchTime.now().uptimeNanoseconds

    func mark(_ phase: String, bytes: Int? = nil) {
        let timestamp = DispatchTime.now().uptimeNanoseconds
        let elapsed = timestamp >= startedAt ? timestamp - startedAt : 0
        let count = bytes.map(String.init) ?? "none"
        let line = "capture=\(identifier) phase=\(phase) elapsed_ns=\(elapsed) bytes=\(count)"
        logger.info("\(line, privacy: .public)")
    }

    func recordHelper(_ timing: PasteboardHelperTiming?) {
        guard let timing else { return }
        let samples: [(String, UInt64)] = [
            ("helperMainEntered", timing.mainEntered), ("helperBoardOpened", timing.boardOpened),
            ("helperCaptureFinished", timing.captureFinished), ("helperEncodingStarted", timing.encodingStarted)
        ]
        let now = DispatchTime.now().uptimeNanoseconds
        let timestamps = samples.map(\.1)
        guard timestamps == timestamps.sorted(), timestamps.allSatisfy({ $0 >= startedAt && $0 <= now }) else {
            mark("helperTimingInvalid")
            return
        }
        for (phase, timestamp) in samples {
            let line = "capture=\(identifier) phase=\(phase) elapsed_ns=\(timestamp - startedAt) bytes=none"
            logger.info("\(line, privacy: .public)")
        }
    }
}
