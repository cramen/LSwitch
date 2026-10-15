import Dispatch
import Foundation
import os

/// Диагностика содержит только фазы, причины и время; пользовательский текст не сохраняется.
@MainActor
public final class ConversionDiagnostics {
    public enum Phase: String, Sendable {
        case requested, contextCaptured, holdAcquired, engineStarted
        case clipboardContextCaptured, menuPreparationStarted, menuPrepared, preparationWaitEnded
        case pendingInputDrained, inputQueueDrained, snapshotRead, snapshotReadyWithoutDelay
        case clipboardCaptureStarted, clipboardCaptured, clipboardWriteStarted, clipboardWritten
        case captureHelperLaunchStarted, captureHelperLaunched, captureHelperReturned
        case clipboardRestoreStarted, clipboardRestored
        case selectionKeyboardRequested, selectionApplied, selectionSettled, pasteRequested
        case textConfirmed, layoutDecision, layoutObserved, layoutConfirmed
        case keyboardCommandStarted, keyboardCommandDown, keyboardKeyDown, keyboardCommandReturned
        case unicodeDownRequested
        case rejected, finished
    }

    public enum Mechanism: String, Sendable { case none, accessibility, clipboard, unicode }

    public enum Rejection: String, Sendable {
        case busy, rules, unsupportedLayout, requestInvalid, contextUnavailable, contextChanged
        case generationChanged, applicationChanged, focusedElementUnavailable, focusedElementChanged
        case secureInput, protectedField, holdUnavailable, holdExpired, cancelled
        case clipboardContextUnavailable, snapshotUnavailable, expectedSpanMismatch, engineUnavailable
        case unexpectedSelection, caretBeforeExpectedSpan
        case keyboardSelectionUnavailable, keyboardSelectionRequiresDocumentEnd, keyboardUndoUnavailable
        case clipboardChanged, clipboardNotRestorable, clipboardWriteFailed, selectionFailed
        case clipboardCaptureTimedOut, clipboardCaptureBusy, clipboardCaptureUnavailable
        case textChanged, selectionChanged, textNotConfirmed, layoutNotConfirmed, documentChanged
        case sourceCode, sourceContextUnknown, sourceDocumentChanged, sourceSnapshotUnverified
        case unicodeSnapshotUnverified, unicodeInputSourceUnsupported
        case unicodePayloadUnsupported, unicodePreparationFailed
    }

    public enum Completion: String, Sendable {
        case converted, undone, partiallyConverted, partiallyUndone
        case blockedByRules, blockedBySafety, unsupportedLayout, busy, failed, skipped
    }

    public enum ClockOrigin: String, Sendable { case rawEvent, missing, invalid }

    public struct Sample: Equatable, Sendable {
        public let operationID: UInt64
        public let bundleID: String?
        public let attempt: Int
        public let automatic: Bool
        public let origin: ClockOrigin
        public let mechanism: Mechanism
        public let phase: Phase
        public let reason: Rejection?
        public let completion: Completion?
        public let operationNanoseconds: UInt64?
        public let eventNanoseconds: UInt64?
        #if DEBUG
        var layoutMetadata: ConversionLayoutMetadata?
        #endif

        /// Быстрый отказ и partial не выполняют цель успешного автоисправления ≤200 мс.
        public var meetsAutomaticLatencyTarget: Bool? {
            guard automatic, completion == .converted, let eventNanoseconds else { return nil }
            return eventNanoseconds <= 200_000_000
        }

        var logLine: String {
            let eventTime = eventNanoseconds.map(String.init) ?? "missing"
            let operationTime = operationNanoseconds.map(String.init) ?? "missing"
            let target = meetsAutomaticLatencyTarget.map { String($0) } ?? "not-applicable"
            let layoutFields: String
            #if DEBUG
            layoutFields = layoutMetadata?.logFields ?? ""
            #else
            layoutFields = ""
            #endif
            return "conversion id=\(operationID) app=\(bundleID ?? "unknown") attempt=\(attempt)"
                + " run=\(attempt == 1 ? "first" : "repeat") auto=\(automatic) origin=\(origin.rawValue)"
                + " engine=\(mechanism.rawValue) phase=\(phase.rawValue) reason=\(reason?.rawValue ?? "none")"
                + " result=\(completion?.rawValue ?? "pending") event_ns=\(eventTime) operation_ns=\(operationTime)"
                + " target_200ms=\(target)" + layoutFields
        }
    }

    private static var nextID: UInt64 = 0
    private static let logger = Logger(subsystem: "LSwitch", category: "ConversionDiagnostics")
    private let operationID: UInt64
    private let bundleID: String?
    private let attempt: Int
    private let automatic: Bool
    private let startedAt: UInt64
    private let triggerTimestamp: UInt64?
    private let origin: ClockOrigin
    private let now: () -> UInt64
    private let emit: (Sample) -> Void
    private var mechanism: Mechanism = .none
    private var firstRejection: Rejection?
    private var completed = false
    #if DEBUG
    private var layoutMetadata: ConversionLayoutMetadata?
    #endif

    public convenience init(bundleID: String?, triggerTimestamp: UInt64?, attempt: Int, automatic: Bool) {
        self.init(
            bundleID: bundleID, triggerTimestamp: triggerTimestamp, attempt: attempt, automatic: automatic,
            now: { DispatchTime.now().uptimeNanoseconds },
            emit: { sample in Self.logger.notice("\(sample.logLine, privacy: .public)") }
        )
    }

    init(
        bundleID: String?, triggerTimestamp: UInt64?, attempt: Int, automatic: Bool,
        now: @escaping () -> UInt64, emit: @escaping (Sample) -> Void
    ) {
        Self.nextID &+= 1
        self.operationID = Self.nextID
        self.bundleID = bundleID
        self.attempt = attempt
        self.automatic = automatic
        self.now = now
        self.emit = emit
        self.startedAt = now()
        if let triggerTimestamp, triggerTimestamp > 0, triggerTimestamp <= startedAt {
            self.triggerTimestamp = triggerTimestamp
            self.origin = .rawEvent
        } else {
            self.triggerTimestamp = nil
            self.origin = triggerTimestamp == nil ? .missing : .invalid
        }
        mark(.requested)
    }

    public func mark(_ phase: Phase, mechanism: Mechanism? = nil) {
        guard !completed else { return }
        if let mechanism { self.mechanism = mechanism }
        record(phase: phase, completion: nil)
    }

    func recordLayoutDecision(source: Layout, target: Layout, receipt: ConversionReceipt) {
        #if DEBUG
        layoutMetadata = ConversionLayoutMetadata(
            source: source, target: target,
            original: ConversionLayoutMetadata.alphabet(receipt.original),
            converted: ConversionLayoutMetadata.alphabet(receipt.converted)
        )
        mark(.layoutDecision)
        #endif
    }

    func recordLayoutObservation(stage: LayoutObservationStage, accepted: Bool?, observed: Layout?) {
        #if DEBUG
        layoutMetadata?.stage = stage.rawValue
        layoutMetadata?.accepted = accepted
        layoutMetadata?.observed = observed
        mark(.layoutObserved)
        #endif
    }

    @discardableResult
    public func reject(_ reason: Rejection) -> Bool {
        if firstRejection == nil, !completed {
            firstRejection = reason
            record(phase: .rejected, completion: nil)
        }
        return false
    }

    public func complete(_ completion: Completion) {
        guard !completed else { return }
        record(phase: .finished, completion: completion)
        completed = true
    }

    func finish(_ outcome: Converter.Outcome) {
        let completion: Completion
        switch outcome {
        case .converted: completion = .converted
        case .undone: completion = .undone
        case .partiallyConverted: completion = .partiallyConverted
        case .partiallyUndone: completion = .partiallyUndone
        case .blockedByRules: completion = .blockedByRules
        case .blockedBySafety: completion = .blockedBySafety
        case .unsupportedLayout: completion = .unsupportedLayout
        case .busy: completion = .busy
        case .failed: completion = .failed
        }
        complete(completion)
    }

    private func record(phase: Phase, completion: Completion?) {
        let timestamp = now()
        let eventTime = triggerTimestamp.flatMap { timestamp >= $0 ? timestamp - $0 : nil }
        let sample = Sample(
            operationID: operationID, bundleID: bundleID, attempt: attempt, automatic: automatic,
            origin: origin, mechanism: mechanism, phase: phase, reason: firstRejection, completion: completion,
            operationNanoseconds: timestamp >= startedAt ? timestamp - startedAt : nil,
            eventNanoseconds: eventTime
        )
        #if DEBUG
        var annotated = sample
        annotated.layoutMetadata = layoutMetadata
        emit(annotated)
        #else
        emit(sample)
        #endif
    }
}
