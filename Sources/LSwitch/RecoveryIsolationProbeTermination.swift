#if DEBUG
import Foundation

@MainActor
extension RecoveryIsolationProbeController {
    /// Даже диагностический timeout не удаляет уже удержанный ввод без явного решения пользователя.
    func finish(_ result: String) {
        guard !finished else { return }
        if quitAuthorized || !hasPendingInputOwnership || verifiedPreMutationRefusal(result) {
            shutdown(result)
            return
        }
        if pendingFinishReason == nil || (pendingFinishReason == "operator_finished" && result != "operator_finished") {
            pendingFinishReason = result
        }
        if result == "operator_finished" { quitDeclined = false }
        processPendingQuit()
    }

    private var hasPendingInputOwnership: Bool {
        guard let report = session?.report else { return false }
        return report.retainedBeforeAdoption || report.adopted || report.ledgerSubmissionCount > 0
    }

    private func verifiedPreMutationRefusal(_ result: String) -> Bool {
        guard result == "pre_mutation_refused", fault == .beforeSelection,
              captureTransport == .recipient, captureTap == nil, expectedStopCompleted,
              preMutationRefusalObserved, driver?.snapshot.cleanupCompleted == true,
              let report = session?.report else { return false }
        return report.ledgerSubmissionCount == 0 && report.capturedEvents == 0
            && !report.selectionCommandRegistered && !report.adopted
            && postedPrefixCount == 0 && postedRetiredPrefixCount == 0 && postedChallengeCount == 0
    }

    func processPendingQuit() {
        guard !finished, !quitAuthorized, !quitPromptInFlight, !quitDeclined,
              let reason = pendingFinishReason, let session else { return }
        // Это лишь передача уже принятой очереди. Внешний получатель и old commands не объявляются безопасными.
        if session.metadata == nil {
            guard session.finishForStorageRecovery() else { return }
            captureTap?.stop()
        }
        if !recoveryPresented { showRecovery() }
        quitPromptInFlight = true
        recoveryWindow.requestQuit(actions: session.quitActions) { [weak self] allowed in
            guard let self, !self.finished else { return }
            self.quitPromptInFlight = false
            self.quitDeclined = !allowed
            if allowed {
                self.quitAuthorized = true
                self.shutdown(self.pendingFinishReason ?? reason)
            } else {
                self.printReport(event: "quit_cancelled_retained")
            }
        }
    }

    @objc func requestFixtureAbort() {
        guard stage == .interactive else { return }
        finish("diagnostic_abort")
    }
}
#endif
