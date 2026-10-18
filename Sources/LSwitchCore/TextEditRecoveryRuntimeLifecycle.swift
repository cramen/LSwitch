#if DEBUG
import Foundation

extension TextEditRecoveryRuntime {
    public func finishInvocation(
        _ invocation: TextEditRecoveryInvocation, outcome: Converter.Outcome, actions: TextEditRecoveryInvocationActions
    ) async -> Bool {
        guard let attempt, attempt.invocation == invocation, !attempt.invocationFinished, !attempt.finishing else {
            return false
        }
        attempt.finishing = true
        if let adapter = attempt.adapter, !adapter.ordinaryCompleted {
            if let session = attempt.session { session.retainIfUnfinished() } else { adapter.retainBeforeSession() }
            _ = await adapter.awaitRecovery()
        }
        let mayRelease = attempt.adapter == nil || attempt.adapter?.ordinaryCompleted == true
        let driverStopped = mayRelease ? await stopDriver(attempt) : false
        let disposition = logicalDisposition(attempt)
        let processingActions = EventProcessingActions(
            applyOutcome: { actions.applyOutcome(outcome) }, reset: actions.reset, consume: actions.consume,
            didFinish: { [weak self, weak attempt] in
                guard let self, let attempt, self.attempt === attempt else { return }
                attempt.invocationFinished = true
                attempt.finishing = false
                if driverStopped && mayRelease { self.attempt = nil }
                if attempt.adapter?.ordinaryCompleted == true { self.setStage(.completed) } else {
                    self.onStateChange()
                }
            }
        )
        let finish: EventProcessingFinish
        if let adapter = attempt.adapter {
            finish = await adapter.resources.logical.finish(disposition, processingActions)
        } else if let tap = attempt.tap, let lease = attempt.lease {
            finish = await tap.finishProcessingLease(lease, disposition: disposition, actions: processingActions)
        } else {
            processingActions.applyOutcome()
            processingActions.reset()
            processingActions.didFinish()
            finish = .discarded
        }
        attempt.finishing = false
        guard finish != .stale else { onStateChange(); return false }
        return true
    }

    private func logicalDisposition(_ attempt: TextEditRecoveryAttempt) -> EventProcessingDisposition {
        guard let adapter = attempt.adapter, adapter.ordinaryCompleted, attempt.interruption == nil else {
            return .discard
        }
        let correction = adapter.correction.map {
            QueuedInputCorrection(from: $0.source, to: $0.target, startedAt: $0.startedAt, completedAt: $0.completedAt)
        }
        return .delivered(correction)
    }

    public func invalidate(_ reason: TextEditRecoveryInterruption) {
        guard let attempt else { return }
        attempt.interruption = attempt.interruption ?? reason
        if let tap = attempt.tap { tap.invalidateProcessingLease(reason.logicalReason) }
        attempt.adapter?.interrupt(reason)
        setStage(.interrupted)
        guard let adapter = attempt.adapter else { return }
        if let session = attempt.session { session.retainIfUnfinished() } else if !attempt.preparing {
            adapter.retainBeforeSession()
        }
        Task { @MainActor [weak self] in
            _ = await adapter.awaitRecovery()
            self?.adapterChanged()
        }
    }

    /// Готовность показать quit confirmation, не разрешение удалить RAM или снять неизвестную цель.
    public func prepareForQuit() async -> Bool {
        invalidate(.shutdown)
        for _ in 0..<100 {
            guard !Task.isCancelled else { return false }
            guard let attempt else { return !owner.isOccupied }
            if !attempt.preparing, !attempt.finishing, attempt.invocationFinished {
                if let adapter = attempt.adapter {
                    guard await adapter.awaitRecovery() else { return false }
                    return adapter.adopted || adapter.ordinaryCompleted
                }
                return await stopDriver(attempt)
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    public func shutdownAfterQuitDecision() async -> Bool {
        guard quitAuthorized else { return false }
        guard let attempt else { return !owner.isOccupied }
        guard !attempt.preparing, !attempt.finishing, attempt.invocationFinished else { return false }
        if let adapter = attempt.adapter {
            guard adapter.ordinaryCompleted || adapter.resources.coordinator.metadata?.payloadDeleted == true else {
                return false
            }
        }
        return await stopDriver(attempt)
    }

    private func stopDriver(_ attempt: TextEditRecoveryAttempt) async -> Bool {
        if let adapter = attempt.adapter { return await adapter.stopDriver() }
        return await attempt.driver?.stop() ?? true
    }
}
#endif
