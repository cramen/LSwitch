import AppKit
import LSwitchCore
import os

#if DEBUG
/// Включается только явным флагом. Обычный запуск не использует непроверенный системный профиль.
@MainActor
final class AppRecoveryPilot {
    let runtime: TextEditRecoveryRuntime
    var onAvailabilityChange: (Bool) -> Void = { _ in }
    private let window = RecoveryWindowController()
    private let logger = Logger(subsystem: "LSwitch", category: "RecoveryPilot")
    private var announcedRecord: UUID?
    private var diagnosticSignature: String?
    private var quitPending = false

    init(
        testDocument: URL, faultMode: TextEditRecoveryFaultMode,
        eventTap: @escaping @MainActor () -> EventTapCore?,
        currentSafety: @escaping @MainActor () -> Bool
    ) {
        runtime = TextEditRecoveryRuntime(testDocument: testDocument, faultMode: faultMode,
                                          eventTap: eventTap, currentSafety: currentSafety)
        window.prepare()
        runtime.onStateChange = { [weak self] in self?.refresh() }
    }

    func perform(
        operation: @MainActor () async -> Converter.Outcome,
        actions: TextEditRecoveryInvocationActions
    ) async {
        guard let invocation = runtime.beginInvocation() else {
            actions.applyOutcome(.busy)
            refresh()
            return
        }
        let outcome = await operation()
        _ = await runtime.finishInvocation(invocation, outcome: outcome, actions: actions)
        refresh()
    }

    func invalidate(_ reason: TextEditRecoveryInterruption) { runtime.invalidate(reason) }

    func show() {
        guard let metadata = runtime.metadata else { return }
        runtime.show()
        window.show(metadata, actions: runtime.actions)
    }

    private func refresh() {
        let metadata = runtime.metadata
        let state = runtime.status
        var signature = "stage=\(runtime.diagnosticStage) pending=\(state.hasPending) unsettled=\(state.hasUnsettled) "
            + "metadata=\(state.metadataReady) events=\(metadata?.counts.events ?? 0)"
        if let fault = runtime.faultReport {
            signature += " fault=\(fault.phase.rawValue) selectionAttempts=\(fault.selectionAttempts) "
                + "selectionSucceeded=\(fault.selectionSucceeded) selected=\(fault.selectedRangeObserved) "
                + "prefixEvents=\(fault.capturedEvents) "
                + "countReads=\(fault.payloadCountReads) prefixBytes=\(fault.capturedUTF16Bytes) "
                + "missingReads=\(fault.missingSnapshotReads) blockedWrites=\(fault.blockedWrites)"
        }
        if let profile = runtime.profileReport { signature += " " + profileSummary(profile) }
        if diagnosticSignature != signature {
            diagnosticSignature = signature
            logger.notice("\(signature, privacy: .public)")
        }
        onAvailabilityChange(metadata != nil)
        guard let metadata else { return }
        guard announcedRecord != metadata.recordIdentifier else {
            window.updateMetadata(metadata)
            return
        }
        announcedRecord = metadata.recordIdentifier
        show()
    }

    private func profileSummary(_ report: TextEditRecoveryProfileReport) -> String {
        [
            "request=\(report.requestIsValid.count):\(report.requestIsValid.nanoseconds)",
            "source=\(report.source.count):\(report.source.nanoseconds)",
            "protected=\(report.protectedField.count):\(report.protectedField.nanoseconds)",
            "focus=\(report.focus.count):\(report.focus.nanoseconds)",
            "foreground=\(report.foreground.count):\(report.foreground.nanoseconds)",
            "context=\(report.context.count):\(report.context.nanoseconds)",
            "snapshotInclusive=\(report.snapshotInclusive.count):\(report.snapshotInclusive.nanoseconds)",
            "captured=\(report.capturedEvents):\(report.capturedUTF16Bytes):\(report.payloadCountReads)",
            "profileFault=\(report.profileFault ?? "none")",
            "logicalFailure=\(report.logicalFailure ?? "none")"
        ].joined(separator: " ")
    }

    /// Возвращаем решение NSApplication лишь после RAM handover и подтверждённого локального cleanup.
    func requestQuit(completion: @escaping (Bool) -> Void) {
        guard !quitPending else { return }
        quitPending = true
        Task { [self] in
            guard await runtime.prepareForQuit() else {
                quitPending = false
                refresh()
                completion(false)
                return
            }
            window.requestQuit(actions: runtime.quitActions) { [weak self] allowed in
                guard let self else { completion(false); return }
                guard allowed else {
                    self.quitPending = false
                    completion(false)
                    return
                }
                Task { @MainActor in
                    let stopped = await self.runtime.shutdownAfterQuitDecision()
                    self.quitPending = false
                    completion(stopped)
                }
            }
        }
    }
}
#endif
