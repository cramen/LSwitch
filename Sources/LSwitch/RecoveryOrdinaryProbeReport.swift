#if DEBUG
import Foundation

@MainActor
extension RecoveryOrdinaryProbeController {
    func report() {
        var fields: [String: Any] = [
            "mode": mode.rawValue, "stage": stage.rawValue, "status": status,
            "fixtureOnly": true, "senderPID": getpid(), "targetPID": peer.processID,
            "observed": observed, "initialFlushObserved": initialFlushObserved, "retainedObserved": retainedObserved,
            "postedPrefix": postedPrefix, "postedWakeControl": postedControl, "postedContinuation": postedContinuation,
            "childEOF": childEOF, "childExit": childExit.map { $0 as Any } ?? NSNull(),
            "childStderrBytes": childStderr, "finalReply": finalReply, "childAborted": childAborted,
            "cleanupCompleted": cleanupCompleted, "payloadLogged": false, "automaticClipboardAccess": false,
            "requestedPermissions": false, "rendererACK": false, "productionEnabled": false,
            "elapsedMs": (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
        ]
        if let reply = lastReply {
            fields["receiver"] = [
                "fixtureUnchanged": reply.fixtureTextUnchanged ?? false,
                "fixtureSelectionUnchanged": reply.fixtureSelectionUnchanged ?? false,
                "controlTextMatches": reply.controlTextMatches,
                "controlSelectionMatches": reply.controlSelectionMatches,
                "continuationTextMatches": reply.ordinaryContinuationTextMatches,
                "continuationSelectionMatches": reply.ordinaryContinuationSelectionMatches,
                "wakeReleaseObserved": reply.ordinaryWakeReleaseObserved,
                "changeCount": reply.changeCount ?? 0, "received": reply.received,
                "foreignInput": reply.foreignInput, "overflow": reply.overflow
            ] as [String: Any]
        }
        if let report = owner?.report {
            fields["ordinary"] = [
                "driverStarted": report.started, "captureArmed": report.armed,
                "capturedEvents": report.capturedEvents, "capturedUTF16Bytes": report.capturedUTF16Bytes,
                "payloadCountReads": report.payloadCountReads, "ledgerSubmissions": report.ledgerSubmissions,
                "ordinaryClaim": report.ordinaryClaim, "claimCount": report.claimCount,
                "wakePostAttempts": report.wakePostAttempts, "wakePostReturned": report.wakePostReturned,
                "completed": report.completed, "adopted": report.adopted,
                "retainedEvents": report.retainedEvents, "retainedUTF16Bytes": report.retainedUTF16Bytes,
                "payloadDeleted": report.payloadDeleted, "revealCount": report.revealCount,
                "attemptedPosts": report.delivery?.attemptedPosts ?? 0,
                "returnedPosts": report.delivery?.returnedPosts ?? 0,
                "possiblyAlreadyDelivered": report.delivery?.possiblyAlreadyDelivered ?? false,
                "headEnabled": report.driver.headEnabled, "tailEnabled": report.driver.tailEnabled,
                "protectionAvailable": report.driver.protectionAvailable,
                "cleanupCompleted": report.driver.cleanupCompleted, "loss": report.driver.loss?.rawValue ?? "none"
            ] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
    }
}
#endif
