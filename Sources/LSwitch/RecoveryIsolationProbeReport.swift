#if DEBUG
import Foundation
import LSwitchCore

@MainActor
extension RecoveryIsolationProbeController {
    func printReport(event: String) {
        let retained = sessionBeforeCleanup ?? session?.report
        let protection = driverBeforeCleanup ?? driver?.snapshot
        var fields: [String: Any] = [
            "event": event, "status": status, "stage": stage.rawValue, "fixtureOnly": true,
            "stageBeforeCleanup": stageBeforeCleanup?.rawValue ?? "none", "expectedSequence": expectedSequence,
            "senderPID": getpid(), "targetPID": peer.processID, "separateProcesses": getpid() != peer.processID,
            "prefixPosting": "postToPid", "postedPrefixCount": postedPrefixCount,
            "captureTransport": captureTransport.rawValue,
            "postedRetiredPrefixCount": postedRetiredPrefixCount, "retiredPrefixBlocked": retiredPrefixBlocked,
            "postedChallengeCount": postedChallengeCount, "prefixReceiverUnchanged": prefixUnchanged,
            "challengeBlocked": challengeBlocked, "observationComplete": prefixUnchanged && challengeBlocked,
            "peerLossObserved": peerLossObserved, "childAbortObserved": childAbortObserved,
            "protectionLossObserved": protectionLossObserved,
            "childStderrBytes": childStderrBytes,
            "childExitStatus": childExitStatus.map { $0 as Any } ?? NSNull(),
            "cleanupCompleted": cleanupCompleted, "payloadLogged": false, "automaticClipboardAccess": false,
            "requestedPermissions": false, "replayAuthorized": false, "productionGateAccepted": false,
            "fixtureLifetimeSeconds": 120, "elapsedMs": (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        ]
        if let retained { fields["recovery"] = recoveryFields(retained) }
        if let protection { fields["driver"] = driverFields(protection) }
        if let lastReply = childBeforeCleanup ?? lastReply {
            fields["lastChild"] = [
                "kind": lastReply.kind, "sequence": lastReply.sequence, "received": lastReply.received,
                "fixtureTextUnchanged": lastReply.fixtureTextUnchanged.map { $0 as Any } ?? NSNull(),
                "fixtureSelectionUnchanged": lastReply.fixtureSelectionUnchanged.map { $0 as Any } ?? NSNull(),
                "changes": lastReply.changeCount.map { $0 as Any } ?? NSNull(),
                "foreignInput": lastReply.foreignInput, "overflow": lastReply.overflow,
                "active": lastReply.active, "focused": lastReply.focused
            ] as [String: Any]
        }
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
    }

    private func recoveryFields(_ value: RecoveryIsolationReport) -> [String: Any] {
        [
            "capturedEvents": value.capturedEvents, "capturedUTF16Bytes": value.capturedUTF16Bytes,
            "rejectedFixtureEvents": value.rejectedFixtureEvents, "payloadCountReads": value.payloadCountReads,
            "captureAttached": value.captureAttached, "captureDetached": value.captureDetached,
            "selectionCommandRegistered": value.selectionCommandRegistered, "selectionUnknown": value.selectionUnknown,
            "adopted": value.adopted, "eventsRemaining": value.eventsRemaining,
            "utf16BytesRemaining": value.utf16BytesRemaining, "ledgerSubmissions": value.ledgerSubmissionCount,
            "ledgerHasUnknown": value.ledgerHasUnknown, "recoveryRequired": value.recoveryRequired,
            "inputClaimedForRecovery": value.inputClaimedForRecovery,
            "payloadDeleted": value.payloadDeleted, "revealCount": value.revealCount,
            "retainedBeforeAdoption": value.retainedBeforeAdoption,
            "preAdoptLossUnresolved": value.preAdoptLossUnresolved
        ]
    }

    private func driverFields(_ value: RecipientTapDriverSnapshot) -> [String: Any] {
        [
            "workerRunning": value.workerRunning, "headEnabled": value.headEnabled, "tailEnabled": value.tailEnabled,
            "protectionAvailable": value.protectionAvailable, "permitsMutation": value.permitsMutation,
            "cleanupCompleted": value.cleanupCompleted, "loss": value.loss?.rawValue ?? "none",
            "headAllowed": value.headAllowed, "headBlocked": value.headBlocked, "tailObserved": value.tailObserved,
            "fixtureSuppressed": value.fixtureSuppressed,
            "disableNotifications": value.disableNotifications, "observationsTruncated": value.observationsTruncated,
            "observations": value.observations.map(\.rawValue)
        ]
    }
}
#endif
