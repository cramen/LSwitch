#if DEBUG
import Foundation
import LSwitchCore

@MainActor
extension RecoveryIsolationProbeController {
    var observationsComplete: Bool {
        switch fault {
        case .none:
            return prefixUnchanged && challengeBlocked
                && (captureTransport != .recipient || retiredPrefixBlocked)
        case .beforeSelection: return expectedStopCompleted && preMutationRefusalObserved
        case .beforeAdoption: return expectedStopCompleted && storageRecoveryObserved
        }
    }

    var scenarioCompleted: Bool {
        guard observationsComplete else { return false }
        if fault == .beforeSelection {
            return status == "pre_mutation_refused" && lastReply?.fixtureTextUnchanged == true
                && lastReply?.changeCount == 0 && lastReply?.received.isEmpty == true
        }
        return status == "operator_finished"
    }

    func refuseAfterDriverStop() async {
        guard let driver, let session else { return finish("fault_scope_missing") }
        let stopped = await driver.stop()
        guard !finished else { return }
        session.markPeerUnavailable()
        expectedStopCompleted = stopped && driver.snapshot.cleanupCompleted && !driver.isProtectionAvailable
        preMutationRefusalObserved = !session.beginFixtureSelectionCommand()
            && session.report.ledgerSubmissionCount == 0 && session.report.capturedEvents == 0
        let result = expectedStopCompleted && preMutationRefusalObserved
        finish(result ? "pre_mutation_refused" : "pre_mutation_fault_failed")
    }

    func stopBeforeStorageRetirement() {
        guard let driver, let session else { return finish("fault_scope_missing") }
        stage = .stoppingCapture
        Task {
            let stopped = await driver.stop()
            guard !finished else { return }
            session.markPeerUnavailable()
            expectedStopCompleted = stopped && driver.snapshot.cleanupCompleted && !driver.isProtectionAvailable
            guard expectedStopCompleted else { return finish("fault_stop_unconfirmed") }
            retirementStartedAt = DispatchTime.now().uptimeNanoseconds
            stage = .retiringCapture
        }
    }

    func observeStorageRetirement(now: UInt64) {
        guard let session, let retirementStartedAt else { return finish("retirement_scope_missing") }
        if session.finishForStorageRecovery() {
            guard let sequence = peer.send(.snapshot) else { return finish("storage_snapshot_failed") }
            expectedSequence = sequence
            stage = .storageSnapshot
        } else if now - retirementStartedAt > 1_000_000_000 { finish("storage_retirement_unconfirmed") }
    }

    func observeStorageSnapshot(_ message: IsolationChildMessage) {
        guard message.fixtureTextUnchanged == true, message.fixtureSelectionUnchanged == true,
              message.changeCount == 0, message.received.isEmpty, let report = session?.report,
              report.capturedEvents == 2, report.capturedUTF16Bytes == 16, report.payloadCountReads == 2,
              report.captureDetached, report.adopted, report.storageOnlyAdopted,
              report.eventsRemaining == 2, report.utf16BytesRemaining == 16,
              report.ledgerHasUnknown, report.recoveryRequired, report.inputClaimedForRecovery,
              driver?.snapshot.fixtureSuppressed == 2, driver?.isProtectionAvailable == false else {
            return finish("storage_recovery_observation_failed")
        }
        prefixUnchanged = true
        storageRecoveryObserved = true
        stage = .interactive
        status = "storage_ready"
        showRecovery()
        printReport(event: "storage_ready")
    }
}
#endif
