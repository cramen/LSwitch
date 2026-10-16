#if DEBUG
import AppKit
import CoreGraphics
import LSwitchCore

@MainActor
extension RecoveryIsolationProbeController {
    func handle(_ message: IsolationChildMessage) {
        lastReply = message
        if message.kind == "exiting" {
            guard controlledExit(message) else {
                childAbortObserved = true
                return finish("child_aborted")
            }
            handlePeerLoss()
            return
        }
        guard message.sequence == expectedSequence, !message.foreignInput, !message.overflow else {
            return finish("child_reply_invalid")
        }
        switch stage {
        case .ready: configureChild(message)
        case .configuring, .focusing: observeFocus(message)
        case .selecting: observeSelection(message)
        default: handleObservation(message)
        }
    }

    func controlledExit(_ message: IsolationChildMessage) -> Bool {
        !message.foreignInput && !message.overflow && (message.reason == "quit" || message.reason == "eof")
    }

    func configureChild(_ message: IsolationChildMessage) {
        guard message.kind == "ready", message.windowTitle == "LSwitch Isolation Receiver \(peer.nonce)",
              let markers else { return finish("child_ready_invalid") }
        let values: [RecoveryIsolationLabel: Int64] = [
            .prefixDown: markers.prefixDown, .prefixRelease: markers.prefixRelease,
            .challengeDown: markers.challengeDown, .challengeRelease: markers.challengeRelease
        ]
        guard let sequence = peer.send(.configure, markers: values) else { return finish("child_configure_failed") }
        expectedSequence = sequence
        stage = .configuring
    }

    func observeFocus(_ message: IsolationChildMessage) {
        guard message.kind == "configured" || message.kind == "snapshot" else { return finish("child_focus_reply") }
        snapshotPending = false
        guard message.fixtureTextUnchanged == true, message.received.isEmpty else {
            return finish("child_fixture_changed")
        }
        if message.active, message.focused,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == peer.processID {
            startCapture()
        } else {
            stage = .focusing
            nextFocusRequestAt = DispatchTime.now().uptimeNanoseconds + 100_000_000
        }
    }

    func requestFocusSnapshot(now: UInt64) {
        guard !snapshotPending else { return }
        guard let sequence = peer.send(.snapshot) else { return finish("focus_snapshot_failed") }
        expectedSequence = sequence
        snapshotPending = true
        nextFocusRequestAt = now + 100_000_000
    }

    func startCapture() {
        guard peer.isRunning, let markers, let session = RecoveryIsolationSession.make(
            targetPID: peer.processID, prefixDownMarker: markers.prefixDown,
            prefixReleaseMarker: markers.prefixRelease
        ), let driver = RecipientTapDriver(bridge: session.bridge) else { return finish("session_unavailable") }
        self.session = session
        self.driver = driver
        stage = .startingDriver
        Task {
            guard await driver.start(), !finished else { return finish("driver_unavailable") }
            guard peer.isRunning, prepareCapture(session: session, driver: driver),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == peer.processID,
                  session.beginFixtureSelectionCommand() else { return finish("capture_preparation_failed") }
            guard let sequence = peer.send(.selectFixture) else { return finish("selection_command_failed") }
            expectedSequence = sequence
            stage = .selecting
        }
    }

    private func prepareCapture(session: RecoveryIsolationSession, driver: RecipientTapDriver) -> Bool {
        if captureTransport == .recipient { return session.prepareRecipientCapture(on: driver) }
        let tap = EventTapCore.recoveryFixtureTap()
        captureTap = tap
        return tap.start() && session.prepareCapture(on: tap, protection: driver)
    }

    func observeSelection(_ message: IsolationChildMessage) {
        guard message.kind == "selected", message.fixtureTextUnchanged == true,
              message.fixtureSelectionUnchanged == true, message.active, message.focused,
              let markers, let session else { return finish("selection_not_observed") }
        session.markFixtureSelectionUnknown(commandReturned: true)
        guard postFixture(marker: markers.prefixDown, isDown: true, text: "kept") else {
            return finish("prefix_down_failed")
        }
        postedPrefixCount += 1
        guard postFixture(marker: markers.prefixRelease, isDown: false, text: "kept") else {
            return finish("prefix_release_failed")
        }
        postedPrefixCount += 1
        prefixPostedAt = DispatchTime.now().uptimeNanoseconds
        stage = .capturing
    }

    func observeCapture(now: UInt64) {
        guard let session, let prefixPostedAt else { return finish("capture_missing") }
        let captured = session.report.capturedEvents
        guard captured == 2 || now - prefixPostedAt > 500_000_000 else { return }
        let adopted = session.finishForRecovery(on: captureTap)
        captureTap?.stop()
        guard adopted else { return finish("capture_handover_unavailable") }
        guard let sequence = peer.send(.snapshot) else { return finish("prefix_snapshot_failed") }
        expectedSequence = sequence
        stage = captured == 2 ? .prefixSnapshot : .captureFailureSnapshot
    }

    func handleObservation(_ message: IsolationChildMessage) {
        guard message.kind == "snapshot" else { return finish("observation_reply_invalid") }
        switch stage {
        case .captureFailureSnapshot: finish("session_capture_unobserved")
        case .prefixSnapshot: observePrefix(message)
        case .retiredPrefixSnapshot: observeRetiredPrefix(message)
        case .challengeSnapshot: observeChallenge(message)
        default: finish("unexpected_child_reply")
        }
    }

    func observePrefix(_ message: IsolationChildMessage) {
        guard message.fixtureTextUnchanged == true, message.fixtureSelectionUnchanged == true,
              message.changeCount == 0, message.received.isEmpty, retainedPrefixMatches,
              driver?.snapshot.tailObserved == 0, let markers else {
            return finish("prefix_reached_receiver")
        }
        prefixUnchanged = true
        if captureTransport == .recipient {
            guard postFixture(marker: markers.prefixDown, isDown: true, text: "kept") else {
                return finish("retired_prefix_down_failed")
            }
            postedRetiredPrefixCount += 1
            guard postFixture(marker: markers.prefixRelease, isDown: false, text: "kept") else {
                return finish("retired_prefix_release_failed")
            }
            postedRetiredPrefixCount += 1
            retiredPrefixPostedAt = DispatchTime.now().uptimeNanoseconds
            stage = .retiredPrefixSnapshot
            nextFocusRequestAt = 0
        } else { beginChallenge() }
    }

    func requestRetiredPrefixSnapshot(now: UInt64) {
        guard !snapshotPending else { return }
        guard let sequence = peer.send(.snapshot) else { return finish("retired_prefix_snapshot_failed") }
        expectedSequence = sequence
        snapshotPending = true
        nextFocusRequestAt = now + 50_000_000
    }

    func observeRetiredPrefix(_ message: IsolationChildMessage) {
        snapshotPending = false
        guard message.fixtureTextUnchanged == true, message.fixtureSelectionUnchanged == true,
              message.changeCount == 0, message.received.isEmpty, let postedAt = retiredPrefixPostedAt else {
            return finish("retired_prefix_reached_receiver")
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - postedAt
        if elapsed >= 150_000_000, retainedPrefixMatches, driver?.snapshot.tailObserved == 0 {
            retiredPrefixBlocked = true
            beginChallenge()
        } else if elapsed > 1_000_000_000 { finish("retired_prefix_observation_timeout") }
    }

    private func beginChallenge() {
        guard let markers else { return finish("challenge_markers_missing") }
        showRecovery()
        guard postFixture(marker: markers.challengeDown, isDown: true, text: "a") else {
            return finish("challenge_down_failed")
        }
        postedChallengeCount += 1
        guard postFixture(marker: markers.challengeRelease, isDown: false, text: "a") else {
            return finish("challenge_release_failed")
        }
        postedChallengeCount += 1
        challengePostedAt = DispatchTime.now().uptimeNanoseconds
        stage = .challengeSnapshot
        nextFocusRequestAt = DispatchTime.now().uptimeNanoseconds + 50_000_000
    }

    func requestChallengeSnapshot(now: UInt64) {
        guard !snapshotPending else { return }
        guard let sequence = peer.send(.snapshot) else { return finish("challenge_snapshot_failed") }
        expectedSequence = sequence
        snapshotPending = true
        nextFocusRequestAt = now + 50_000_000
    }

    func observeChallenge(_ message: IsolationChildMessage) {
        snapshotPending = false
        guard let postedAt = challengePostedAt else { return finish("challenge_missing") }
        let now = DispatchTime.now().uptimeNanoseconds
        guard message.fixtureTextUnchanged == true, message.fixtureSelectionUnchanged == true,
              message.changeCount == 0, !message.received.contains("challengeDown"), retainedPrefixMatches else {
            return finish("challenge_reached_receiver")
        }
        if message.received == ["challengeRelease"], driver?.snapshot.headBlocked == 1 {
            if challengeMatchedAt == nil { challengeMatchedAt = now }
            if let matched = challengeMatchedAt, now - matched >= 150_000_000 {
                guard driver?.refreshProtection() == true, session?.targetIsCurrent == true else {
                    return finish("challenge_protection_lost")
                }
                challengeBlocked = true
                stage = .interactive
                status = "interactive_ready"
                printReport(event: "interactive_ready")
                return
            }
        }
        if now - postedAt > 1_000_000_000 { finish("challenge_observation_timeout") }
    }

    private var retainedPrefixMatches: Bool {
        guard let report = session?.report, report.capturedEvents == 2, report.capturedUTF16Bytes == 16,
              report.payloadCountReads == 2, report.rejectedFixtureEvents == 0,
              report.captureDetached, report.adopted, report.eventsRemaining == 2,
              report.utf16BytesRemaining == 16 else { return false }
        return captureTransport != .recipient || driver?.snapshot.fixtureSuppressed == 2 + postedRetiredPrefixCount
    }

    /// Только собственные fixture marker и точный child PID, независимо от приложения на переднем плане.
    func postFixture(marker: Int64, isDown: Bool, text: String) -> Bool {
        guard peer.isRunning, session?.targetIsCurrent == true, driver?.refreshProtection() == true,
              let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { return false }
        let units = Array(text.utf16)
        event.flags = []
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        guard event.getIntegerValueField(.eventSourceUserData) == marker,
              event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()),
              event.type == (isDown ? .keyDown : .keyUp), event.flags.isEmpty else { return false }
        event.postToPid(peer.processID)
        return true
    }
}
#endif
