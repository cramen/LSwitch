#if DEBUG
import AppKit
import Foundation
import LSwitchCore

@MainActor
extension RecoveryEventMatrixController {
    func finish(_ result: String) {
        guard !finished else { return }
        finished = true
        status = result
        stage = .finishing
        timer?.invalidate()
        timer = nil
        driverBeforeCleanup = driver?.snapshot
        peer.closeInput()
        Task {
            await stopOwnChild()
            let stopped = !peer.isRunning ? (await driver?.stop() ?? true) : false
            cleanupCompleted = stopped && !peer.isRunning && (peer.processID == 0 || childEOF)
            if !cleanupCompleted { status = "cleanup_unconfirmed" }
            shutdownAttemptFinished = true
            window?.orderOut(nil)
            NSApplication.shared.stop(nil)
            if let wake = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
            ) { NSApplication.shared.postEvent(wake, atStart: false) }
        }
    }

    private func stopOwnChild() async {
        await waitForChildStop(attempts: 20)
        if peer.isRunning { peer.terminateIfRunning() }
        await waitForChildStop(attempts: 10)
        if peer.isRunning, anchor?.targetIsCurrent == true { peer.forceTerminateIfRunning() }
        await waitForChildStop(attempts: 10)
        consumeFinalMailbox()
        for _ in 0..<20 where !childEOF && peer.processID != 0 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            consumeFinalMailbox()
        }
    }

    private func waitForChildStop(attempts: Int) async {
        for _ in 0..<attempts where peer.isRunning { try? await Task.sleep(nanoseconds: 25_000_000) }
    }

    private func consumeFinalMailbox() {
        if let mailbox = peer.take() {
            childEOF = childEOF || mailbox.eof
            childExit = mailbox.exitStatus ?? childExit
            childStderr = mailbox.stderrBytes
            if mailbox.failure != nil { status = "child_protocol_failure" }
            for message in mailbox.messages where message.kind == "exiting" {
                finalReply = true
                if message.reason != "eof" || message.foreignInput || message.overflow {
                    status = "child_abort"
                }
            }
        }
        childExit = peer.exitStatus ?? childExit
        if let childExit, childExit != 0 { status = "child_exit_failure" }
    }

    func report() {
        var fields: [String: Any] = [
            "mode": mode.rawValue, "stage": stage.rawValue, "status": status, "keyboardOnly": keyboardOnly,
            "keyboardRoute": keyboardRoute.rawValue,
            "senderPID": getpid(), "targetPID": peer.processID, "postedKeyboardCount": postedCount,
            "senderActive": NSApplication.shared.isActive,
            "senderFrontmost": NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(),
            "receiverFrontmost": peer.isRunning
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == peer.processID,
            "balancingReleasePosts": balancingReleases, "unpostedReleaseDebt": keyboardDebtUnresolved,
            "childEOF": childEOF, "childExit": childExit.map { $0 as Any } ?? NSNull(),
            "childStderrBytes": childStderr, "finalReply": finalReply, "cleanupCompleted": cleanupCompleted,
            "capturePrepared": false, "payloadLogged": false, "automaticClipboardAccess": false,
            "requestedPermissions": false, "rendererACK": false, "productionGateAccepted": false,
            "elapsedMs": (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        ]
        if let reply = lastReply {
            fields["child"] = [
                "matrixArmed": reply.matrixArmed, "matrixLocal": reply.matrixLocal,
                "matrixDispatch": reply.matrixDispatch,
                "matrixShortcut": reply.matrixShortcut,
                "matrixEditor": reply.matrixEditor,
                "textUnchanged": reply.fixtureTextUnchanged ?? false,
                "allSelected": reply.fixtureSelectionUnchanged ?? false,
                "changeCount": reply.changeCount ?? 0, "active": reply.active, "focused": reply.focused,
                "foreignInput": reply.foreignInput, "overflow": reply.overflow
            ] as [String: Any]
        }
        if let value = driverBeforeCleanup ?? driver?.snapshot {
            fields["driver"] = [
                "workerRunning": value.workerRunning, "headEnabled": value.headEnabled,
                "tailEnabled": value.tailEnabled, "headAllowed": value.headAllowed,
                "headBlocked": value.headBlocked, "tailObserved": value.tailObserved,
                "protectionAvailable": value.protectionAvailable, "loss": value.loss?.rawValue ?? "none",
                "mouseButtonsReleased": value.mouseButtonsReleased,
                "eventKinds": RecipientEventKind.allCases.map(\.rawValue),
                "allowed": value.eventCounters.allowed, "blocked": value.eventCounters.blocked,
                "tail": value.eventCounters.tail, "captured": value.eventCounters.captured,
                "truncated": value.observationsTruncated, "observations": value.observations.map(\.rawValue)
            ] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }
}
#endif
