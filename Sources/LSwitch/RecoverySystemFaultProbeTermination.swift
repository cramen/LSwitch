#if DEBUG
import AppKit
import Foundation

@MainActor
extension RecoverySystemFaultProbeController {
    func retainPrefix() async -> Bool {
        guard let owner, owner.hasPendingInput else { return false }
        for _ in 0..<50 {
            if owner.retireForStorage() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func finish(_ reason: String) {
        continuation.stop()
        guard !finished, !quitPending else { return }
        status = pairInconclusive ? "packet_pair_inconclusive" : reason
        guard owner?.hasPendingInput == true else { shutdown(); return }
        quitPending = true
        Task { [weak self] in
            guard let self else { return }
            guard await self.retainPrefix(), let owner = self.owner else {
                self.quitPending = false
                self.phase = .interactive
                self.status = "retirement_pending"
                self.report()
                return
            }
            self.reopenRecovery()
            self.window.requestQuit(actions: owner.quitActions) { [weak self] allowed in
                guard let self else { return }
                self.quitPending = false
                if allowed { self.shutdown() } else {
                    self.phase = .interactive
                    self.status = "quit_cancelled_retained"
                    self.report()
                }
            }
        }
    }

    private func shutdown() {
        guard !finished else { return }
        finished = true
        phase = .finishing
        timer?.invalidate()
        timer = nil
        peer.closeInput()
        Task { [self] in
            guard await closeChild() else {
                finished = false
                phase = .interactive
                status = "child_cleanup_unconfirmed"
                report()
                return
            }
            cleanupCompleted = await owner?.stop() ?? true
            window.hide()
            shutdownFinished = true
            NSApplication.shared.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                            timestamp: 0, windowNumber: 0, context: nil,
                                            subtype: 0, data1: 0, data2: 0) {
                NSApplication.shared.postEvent(wake, atStart: false)
            }
        }
    }

    private func closeChild() async -> Bool {
        for _ in 0..<20 where peer.isRunning { try? await Task.sleep(nanoseconds: 25_000_000) }
        if peer.isRunning { peer.terminateIfRunning() }
        for _ in 0..<20 where peer.isRunning { try? await Task.sleep(nanoseconds: 25_000_000) }
        if peer.isRunning { peer.forceTerminateIfRunning() }
        for _ in 0..<40 where peer.isRunning { try? await Task.sleep(nanoseconds: 25_000_000) }
        for _ in 0..<40 {
            consumeFinalMailbox()
            if childEOF || peer.processID == 0 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return !peer.isRunning && (peer.processID == 0 || childEOF)
    }

    private func consumeFinalMailbox() {
        guard let mailbox = peer.take() else { return }
        childEOF = childEOF || mailbox.eof
        if mailbox.eof, !peer.isRunning { peer.cancelSecureWatchdog() }
        childExit = mailbox.exitStatus ?? peer.exitStatus ?? childExit
        if mailbox.failure != nil || (childExit != nil && childExit != 0) { childAborted = true }
        for reply in mailbox.messages where reply.kind == "exiting" {
            finalReply = true
            if reply.reason != "eof" || reply.foreignInput || reply.overflow { childAborted = true }
            if !reply.secure.isEmpty {
                secureBalanced = reply.secure["owned"] == false
                    && reply.secureCounts["enable"] == reply.secureCounts["disable"]
            }
        }
    }

    func report() {
        var values: [String: Any] = [
            "mode": mode.rawValue, "phase": phase.rawValue, "status": status,
            "route": route.rawValue, "physicalInputTested": false,
            "observed": observed, "beforeArmRefused": beforeArmRefused,
            "postedPrefix": postedPrefix, "postedLateProbe": postedLate,
            "balancingReleasePosts": balancingReleases, "unpostedReleaseDebt": keyboardDebtUnresolved,
            "pairInconclusive": pairInconclusive,
            "secureBalanced": secureBalanced, "secureWatchdogFired": peer.secureWatchdogFired,
            "childEOF": childEOF, "finalReply": finalReply,
            "childExit": childExit.map { $0 as Any } ?? NSNull(), "childAborted": childAborted,
            "cleanupCompleted": cleanupCompleted, "fixtureOnly": true,
            "productionEnabled": false, "privacyGuardAccepted": false, "payloadLogged": false
        ]
        if let reply = lastReply {
            values["receiver"] = ["received": reply.received, "changeCount": reply.changeCount ?? 0,
                "fixtureUnchanged": reply.fixtureTextUnchanged ?? false,
                "fixtureSelectionUnchanged": reply.fixtureSelectionUnchanged ?? false,
                "secure": reply.secure, "secureCounts": reply.secureCounts] as [String: Any]
        }
        if let report = owner?.report {
            values["capture"] = ["started": report.started, "armAttempted": report.armAttempted,
                "armed": report.armed, "observedSecure": report.observedSecure,
                "disableRequested": report.disableRequested, "disableConfirmed": report.disableConfirmed,
                "headEnabled": report.driver.headEnabled, "tailEnabled": report.driver.tailEnabled,
                "capturedEvents": report.session.capturedEvents, "capturedBytes": report.session.capturedUTF16Bytes,
                "countReads": report.session.payloadCountReads, "remainingEvents": report.session.eventsRemaining,
                "storageOnlyAdopted": report.session.storageOnlyAdopted,
                "recoveryClaim": report.session.inputClaimedForRecovery,
                "privacyGuardAccepted": report.privacyGuardAccepted] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
    }
}
#endif
