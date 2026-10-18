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
        testDocument: URL, eventTap: @escaping @MainActor () -> EventTapCore?,
        currentSafety: @escaping @MainActor () -> Bool
    ) {
        runtime = TextEditRecoveryRuntime(testDocument: testDocument, eventTap: eventTap, currentSafety: currentSafety)
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
        let signature = "stage=\(runtime.diagnosticStage) pending=\(state.hasPending) unsettled=\(state.hasUnsettled) "
            + "metadata=\(state.metadataReady) events=\(metadata?.counts.events ?? 0)"
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
