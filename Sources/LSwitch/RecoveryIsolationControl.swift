import AppKit
import CoreGraphics
import LSwitchCore

/// Контроль обычного receiver dispatch. Не создаёт gate, tap или захват удержанного ввода.
@MainActor
enum RecoveryIsolationControl {
    static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.contains("--recovery-isolation-control") else { return nil }
        #if DEBUG
        guard Bundle.main.bundleIdentifier == "ru.cramen.lswitch" else { return 2 }
        let controller = RecoveryIsolationControlController()
        return withExtendedLifetime(controller) { controller.run() }
        #else
        return 2
        #endif
    }
}

#if DEBUG
private enum IsolationControlStage { case ready, configuring, selecting, waitingFocus, observing }

@MainActor
private final class RecoveryIsolationControlController: NSObject, NSApplicationDelegate {
    private let peer = RecoveryIsolationChildProcess()
    private let started = DispatchTime.now().uptimeNanoseconds
    private var identityAnchor: RecoveryIsolationSession?
    private var markers: RecoveryIsolationFixtureMarkers?
    private var timer: Timer?
    private var stage = IsolationControlStage.ready
    private var expectedSequence = 0
    private var pendingSnapshot = false
    private var nextSnapshotAt: UInt64 = 0
    private var postedAt: UInt64?
    private var matchedAt: UInt64?
    private var postedCount = 0
    private var observed = false
    private var finished = false
    private var cleanupCompleted = false
    private var childAborted = false
    private var childEOFObserved = false
    private var finalReplyObserved = false
    private var childStderrBytes = 0
    private var childExitStatus: Int32?
    private var lastObservation: IsolationChildMessage?
    private var status = "starting"

    func run() -> Int32 {
        let application = NSApplication.shared
        guard CGPreflightPostEventAccess() else {
            status = "post_permission_unavailable"
            cleanupCompleted = true
            report()
            return 2
        }
        let priorDelegate = application.delegate
        let priorPolicy = application.activationPolicy()
        application.delegate = self
        _ = application.setActivationPolicy(.accessory)
        application.run()
        application.delegate = priorDelegate
        _ = application.setActivationPolicy(priorPolicy)
        report()
        return observed && cleanupCompleted && finalReplyObserved && !childAborted && childExitStatus == 0 ? 0 : 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let markers = RecoveryIsolationSession.allocateFixtureMarkers() else { return finish("markers_failed") }
        self.markers = markers
        guard peer.start(), let anchor = RecoveryIsolationSession.make(
            targetPID: peer.processID, prefixDownMarker: markers.prefixDown,
            prefixReleaseMarker: markers.prefixRelease
        ) else { return finish("child_start_or_identity_failed") }
        // Session используется только как PID+birth anchor: prepare/reserve/activate не вызываются.
        identityAnchor = anchor
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finish("operator_cancelled")
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func tick() {
        guard !finished, consumeMailbox() else { return }
        guard peer.isRunning, identityAnchor?.targetIsCurrent == true else { return finish("child_identity_lost") }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - started < 10_000_000_000 else { return finish("control_timeout") }
        if let postedAt, now - postedAt > 2_000_000_000 { return finish("receiver_observation_timeout") }
        if stage == .waitingFocus || stage == .observing, now >= nextSnapshotAt, !pendingSnapshot {
            guard let sequence = peer.send(.snapshot) else { return finish("snapshot_failed") }
            expectedSequence = sequence
            pendingSnapshot = true
            nextSnapshotAt = now + 50_000_000
        }
    }

    private func consumeMailbox() -> Bool {
        guard let mailbox = peer.take() else { return true }
        childStderrBytes = mailbox.stderrBytes
        childExitStatus = mailbox.exitStatus ?? childExitStatus
        if let failure = mailbox.failure { finish(failure); return false }
        for message in mailbox.messages {
            handle(message)
            if finished { return false }
        }
        if mailbox.eof { finish("unexpected_child_eof"); return false }
        return true
    }

    private func handle(_ message: IsolationChildMessage) {
        guard message.kind != "exiting", message.sequence == expectedSequence,
              !message.foreignInput, !message.overflow else { return finish("child_reply_invalid") }
        switch stage {
        case .ready: configure(message)
        case .configuring:
            guard message.kind == "configured", pristine(message), identityAnchor?.targetIsCurrent == true,
                  let sequence = peer.send(.selectFixture) else { return finish("selection_command_failed") }
            expectedSequence = sequence
            stage = .selecting
        case .selecting, .waitingFocus: waitForSelectionFocus(message)
        case .observing: observeResult(message)
        }
    }

    private func configure(_ message: IsolationChildMessage) {
        guard message.kind == "ready", message.windowTitle == "LSwitch Isolation Receiver \(peer.nonce)",
              pristine(message), let markers else { return finish("child_ready_invalid") }
        let values: [RecoveryIsolationLabel: Int64] = [
            .prefixDown: markers.prefixDown, .prefixRelease: markers.prefixRelease,
            .challengeDown: markers.challengeDown, .challengeRelease: markers.challengeRelease
        ]
        guard let sequence = peer.send(.configure, markers: values) else { return finish("configure_failed") }
        expectedSequence = sequence
        stage = .configuring
    }

    private func waitForSelectionFocus(_ message: IsolationChildMessage) {
        let expectedKind = stage == .selecting ? "selected" : "snapshot"
        guard message.kind == expectedKind, pristine(message), message.fixtureSelectionUnchanged == true else {
            return finish("selection_not_observed")
        }
        pendingSnapshot = false
        guard message.active, message.focused, hasOwnChildFocus else {
            stage = .waitingFocus
            nextSnapshotAt = DispatchTime.now().uptimeNanoseconds + 50_000_000
            return
        }
        guard let markers, post(marker: markers.prefixDown, down: true) else { return finish("down_failed") }
        postedCount += 1
        guard post(marker: markers.prefixRelease, down: false) else { return finish("release_failed") }
        postedCount += 1
        postedAt = DispatchTime.now().uptimeNanoseconds
        nextSnapshotAt = (postedAt ?? 0) + 50_000_000
        stage = .observing
    }

    private func observeResult(_ message: IsolationChildMessage) {
        guard message.kind == "snapshot", message.active, message.focused, hasOwnChildFocus else {
            return finish("observation_focus_lost")
        }
        pendingSnapshot = false
        lastObservation = message
        let pair = [RecoveryIsolationLabel.prefixDown.rawValue, RecoveryIsolationLabel.prefixRelease.rawValue]
        guard message.controlTextMatches, message.controlSelectionMatches, message.changeCount == 1,
              message.received == pair else { matchedAt = nil; return }
        let now = DispatchTime.now().uptimeNanoseconds
        if matchedAt == nil { matchedAt = now }
        guard let matchedAt, now - matchedAt >= 150_000_000 else { return }
        observed = true
        finish("receiver_control_observed")
    }

    private func pristine(_ message: IsolationChildMessage) -> Bool {
        message.fixtureTextUnchanged == true && message.changeCount == 0 && message.received.isEmpty
    }

    private var hasOwnChildFocus: Bool {
        peer.isRunning && identityAnchor?.targetIsCurrent == true
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == peer.processID
    }

    private func post(marker: Int64, down: Bool) -> Bool {
        guard hasOwnChildFocus, let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return false }
        let units = Array("kept".utf16)
        event.flags = []
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()),
              event.getIntegerValueField(.eventSourceUserData) == marker,
              event.type == (down ? .keyDown : .keyUp), event.flags.isEmpty else { return false }
        event.postToPid(peer.processID)
        return true
    }

    private func finish(_ result: String) {
        guard !finished else { return }
        finished = true
        status = result
        timer?.invalidate()
        timer = nil
        peer.closeInput()
        Task {
            for _ in 0..<20 where peer.isRunning { try? await Task.sleep(nanoseconds: 25_000_000) }
            if peer.isRunning { peer.terminateIfRunning() }
            for _ in 0..<10 where peer.isRunning { try? await Task.sleep(nanoseconds: 25_000_000) }
            consumeFinalMailbox()
            for _ in 0..<10 where !childEOFObserved && peer.processID != 0 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                consumeFinalMailbox()
            }
            cleanupCompleted = !peer.isRunning && (peer.processID == 0 || childEOFObserved)
            if !cleanupCompleted { status = "cleanup_unconfirmed" }
            if observed, !finalReplyObserved { status = "final_reply_unconfirmed" }
            NSApplication.shared.stop(nil)
            if let wake = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
            ) { NSApplication.shared.postEvent(wake, atStart: false) }
        }
    }

    private func consumeFinalMailbox() {
        if let mailbox = peer.take() {
            childStderrBytes = mailbox.stderrBytes
            childExitStatus = mailbox.exitStatus ?? childExitStatus
            childEOFObserved = childEOFObserved || mailbox.eof
            if mailbox.failure != nil { childAborted = true }
            for message in mailbox.messages where message.kind == "exiting" {
                finalReplyObserved = true
                if message.reason != "eof" || message.foreignInput || message.overflow { childAborted = true }
                if observed && (!message.controlTextMatches || !message.controlSelectionMatches
                    || message.changeCount != 1 || message.received != ["prefixDown", "prefixRelease"]) {
                    childAborted = true
                }
            }
        }
        childExitStatus = peer.exitStatus ?? childExitStatus
        if childExitStatus != 0 { childAborted = true }
    }

    private func report() {
        let fields: [String: Any] = [
            "mode": "receiver_baseline_control", "status": status, "receiverControlObserved": observed,
            "senderPID": getpid(), "targetPID": peer.processID, "postedCount": postedCount,
            "received": lastObservation?.received ?? [],
            "controlTextMatches": lastObservation?.controlTextMatches ?? false,
            "controlSelectionMatches": lastObservation?.controlSelectionMatches ?? false,
            "changeCount": lastObservation?.changeCount ?? 0, "childAborted": childAborted,
            "childExitStatus": childExitStatus.map { $0 as Any } ?? NSNull(), "childStderrBytes": childStderrBytes,
            "childEOFObserved": childEOFObserved, "finalReplyObserved": finalReplyObserved,
            "cleanupCompleted": cleanupCompleted, "tapCreated": false, "capturePrepared": false,
            "gateActivated": false, "fixtureOnly": true, "payloadLogged": false, "automaticClipboardAccess": false,
            "requestedPermissions": false, "recoveryGateAccepted": false, "safetyPassed": false,
            "elapsedMs": (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        ]
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
    }
}
#endif
