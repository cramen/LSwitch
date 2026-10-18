#if DEBUG
import ApplicationServices
import Foundation

public enum TextEditRecoveryFaultMode: String, Sendable {
    case none
    case missingAfterSelection = "missing-after-selection"
}

public enum TextEditRecoveryFaultPhase: String, Sendable {
    case ready, waitingForPrefix, injected, inconclusive
}

/// Только metadata инъекции. Ни текст документа, ни held payload не входят в отчёт.
public struct TextEditRecoveryFaultReport: Equatable, Sendable {
    public let phase: TextEditRecoveryFaultPhase
    public let selectionAttempts: Int
    public let selectionSucceeded: Bool
    public let selectedRangeObserved: Bool
    public let capturedEvents: Int
    public let payloadCountReads: Int
    public let capturedUTF16Bytes: Int
    public let missingSnapshotReads: Int
    public let blockedWrites: Int
}

/// Один экземпляр на invocation. Ошибка не создаёт ни native событий, ни дополнительных AX setters.
@MainActor
final class TextEditRecoveryFaultFixture {
    typealias Snapshot = (AXUIElement, () -> Bool) -> AXProfileSnapshot?
    private let now: () -> UInt64
    private let pause: () async -> Void
    private var capture: Capture?
    private var phase = TextEditRecoveryFaultPhase.ready
    private var selectionAttempts = 0
    private var selectionSucceeded = false
    private var selectedRangeObserved = false
    private var missingSnapshotReads = 0
    private var blockedWrites = 0
    private var denySnapshot = false
    private var observed = RecoveryCaptureCounters(
        capturedEvents: 0, capturedUTF16Bytes: 0, rejectedEvents: 0, payloadCountReads: 0)

    private struct Capture {
        let deadline: UInt64
        let isCurrent: () -> Bool
        let counters: () -> RecoveryCaptureCounters
    }

    init(
        now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        pause: @escaping () async -> Void = { try? await Task.sleep(nanoseconds: 2_000_000) }
    ) {
        self.now = now
        self.pause = pause
    }

    func bind(deadline: UInt64, isCurrent: @escaping () -> Bool, counters: @escaping () -> RecoveryCaptureCounters) {
        guard capture == nil, selectionAttempts == 0 else { return }
        capture = .init(deadline: deadline, isCurrent: isCurrent, counters: counters)
    }

    func beginSelection() -> Bool {
        guard selectionAttempts == 0, !denySnapshot else { blockedWrites += 1; return false }
        selectionAttempts += 1
        return true
    }

    func didSelect(_ status: AXError) {
        selectionSucceeded = status == .success
        if !selectionSucceeded { failInconclusive() }
    }

    func blockWrite() { blockedWrites += 1 }

    func snapshot(_ element: AXUIElement, canRead: () -> Bool, original: @escaping Snapshot) -> AXProfileSnapshot? {
        guard !denySnapshot else { missingSnapshotReads += 1; return nil }
        return original(element, { canRead() })
    }

    func waitForPrefix(selectionMatches: () -> Bool) async {
        guard phase == .ready, selectionSucceeded, let capture else { failInconclusive(); return }
        phase = .waitingForPrefix
        selectedRangeObserved = capture.isCurrent() && selectionMatches()
        guard selectedRangeObserved else { failInconclusive(); return }
        let started = now()
        let end = min(capture.deadline, started.addingReportingOverflow(100_000_000).partialValue)
        while !Task.isCancelled, now() < end, capture.isCurrent() {
            observed = capture.counters()
            if observed.capturedEvents >= 2, observed.payloadCountReads >= 2, observed.capturedUTF16Bytes > 0 {
                selectedRangeObserved = selectionMatches()
                guard selectedRangeObserved, now() < end, capture.isCurrent(), !Task.isCancelled else { break }
                denySnapshot = true
                phase = .injected
                return
            }
            await pause()
        }
        observed = capture.counters()
        failInconclusive()
    }

    private func failInconclusive() {
        denySnapshot = true
        if phase != .injected { phase = .inconclusive }
    }

    var report: TextEditRecoveryFaultReport {
        .init(phase: phase, selectionAttempts: selectionAttempts, selectionSucceeded: selectionSucceeded,
              selectedRangeObserved: selectedRangeObserved, capturedEvents: observed.capturedEvents,
              payloadCountReads: observed.payloadCountReads, capturedUTF16Bytes: observed.capturedUTF16Bytes,
              missingSnapshotReads: missingSnapshotReads, blockedWrites: blockedWrites)
    }
}
#endif
