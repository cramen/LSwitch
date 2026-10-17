#if DEBUG
import AppKit
import Foundation

@MainActor
extension RecoveryOrdinaryProbeController {
    func finish(_ result: String) {
        guard !finished, !cleanupInProgress else { return }
        if quitAuthorized || owner?.hasPendingInput != true { shutdown(result); return }
        if pendingFinishReason == nil || result != "operator_finished" { pendingFinishReason = result }
        processPendingFinish()
    }

    func processPendingFinish() {
        guard !finished, !retentionInProgress, !quitPrompt, !quitDeclined,
              let reason = pendingFinishReason, let owner else { return }
        retentionInProgress = true
        Task { [weak self] in
            let retained = await owner.retainForRecovery()
            guard let self else { return }
            self.retentionInProgress = false
            guard !self.finished else { return }
            if owner.report.completed { self.shutdown(reason); return }
            guard retained else { self.status = "handover_pending"; return }
            self.showRecovery()
            self.quitPrompt = true
            self.recoveryWindow.requestQuit(actions: owner.quitActions) { [weak self] allowed in
                guard let self else { return }
                self.quitPrompt = false
                self.quitDeclined = !allowed
                if allowed {
                    self.quitAuthorized = true
                    self.shutdown(self.pendingFinishReason ?? reason)
                } else {
                    self.status = "quit_cancelled_retained"
                    self.report()
                }
            }
        }
    }

    private func shutdown(_ result: String) {
        guard !cleanupInProgress, !shutdownFinished else { return }
        cleanupInProgress = true
        finished = true
        status = result
        stage = .finishing
        timer?.invalidate()
        timer = nil
        peer.closeInput()
        Task { [self] in
            guard await closeChildBeforeDriver() else {
                // Не снимаем gate до EOF и не уничтожаем app-owner. Повторный Quit повторит только cleanup.
                status = "child_cleanup_unconfirmed"
                finished = false
                cleanupInProgress = false
                report()
                return
            }
            let stopped = await owner?.stopDriver() ?? true
            cleanupCompleted = stopped
            if !stopped { status = "driver_cleanup_unconfirmed" }
            recoveryWindow.hide()
            cleanupInProgress = false
            shutdownFinished = true
            NSApplication.shared.stop(nil)
            if let wake = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
            ) { NSApplication.shared.postEvent(wake, atStart: false) }
        }
    }

    private func closeChildBeforeDriver() async -> Bool {
        for _ in 0..<20 where peer.isRunning { try? await Task.sleep(nanoseconds: 25_000_000) }
        if peer.isRunning { peer.terminateIfRunning() }
        for _ in 0..<20 where peer.isRunning { try? await Task.sleep(nanoseconds: 25_000_000) }
        if peer.isRunning { peer.forceTerminateIfRunning() }
        for _ in 0..<40 where peer.isRunning { try? await Task.sleep(nanoseconds: 25_000_000) }
        consumeFinalMailbox()
        for _ in 0..<40 where !childEOF && peer.processID != 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            consumeFinalMailbox()
        }
        return !peer.isRunning && (peer.processID == 0 || childEOF)
    }

    private func consumeFinalMailbox() {
        if let mailbox = peer.take() {
            childEOF = childEOF || mailbox.eof
            childExit = mailbox.exitStatus ?? childExit
            childStderr = mailbox.stderrBytes
            if mailbox.failure != nil { childAborted = true }
            for message in mailbox.messages where message.kind == "exiting" {
                finalReply = true
                if message.reason != "eof" || message.foreignInput || message.overflow { childAborted = true }
                if observed && !finalFixtureMatches(message) { childAborted = true }
            }
        }
        childExit = peer.exitStatus ?? childExit
        if let childExit, childExit != 0 { childAborted = true }
    }

    private func finalFixtureMatches(_ message: IsolationChildMessage) -> Bool {
        switch mode {
        case .control:
            return message.fixtureTextUnchanged == true && message.fixtureSelectionUnchanged == true
                && message.changeCount == 0 && message.received == ["challengeRelease"]
                && message.ordinaryWakeReleaseObserved
        case .flush:
            return message.ordinaryContinuationTextMatches && message.ordinaryContinuationSelectionMatches
                && message.changeCount == 2 && !message.ordinaryWakeReleaseObserved
                && message.received == ["prefixDown", "prefixRelease", "challengeDown", "prefixRelease"]
        case .retain:
            return message.fixtureTextUnchanged == true && message.fixtureSelectionUnchanged == true
                && message.changeCount == 0 && message.received.isEmpty && !message.ordinaryWakeReleaseObserved
        }
    }
}
#endif
