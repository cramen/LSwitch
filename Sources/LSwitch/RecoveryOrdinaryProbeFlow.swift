#if DEBUG
import AppKit
import CoreGraphics
import LSwitchCore

@MainActor
extension RecoveryOrdinaryProbeController {
    func consumeMailbox() {
        guard let mailbox = peer.take() else { return }
        childStderr = mailbox.stderrBytes
        childExit = mailbox.exitStatus ?? childExit
        if let failure = mailbox.failure { finish(failure); return }
        for message in mailbox.messages {
            if message.kind == "exiting" {
                childAborted = true
                continue
            }
            guard !finished else { break }
            handle(message)
        }
        if mailbox.eof {
            childEOF = true
            owner?.markPeerLost()
            finish("unexpected_child_eof")
        }
    }

    private func handle(_ message: IsolationChildMessage) {
        guard message.sequence == expectedSequence, !message.foreignInput, !message.overflow else {
            return finish("child_reply_invalid")
        }
        lastReply = message
        switch stage {
        case .ready: configure(message)
        case .configuring:
            guard message.kind == "configured", pristine(message), let sequence = peer.send(.selectFixture) else {
                return finish("fixture_selection_failed")
            }
            expectedSequence = sequence
            stage = .selecting
        case .selecting, .waitingFocus: waitForFocus(message)
        case .observing: observeInitial(message)
        case .continuing: observeContinuation(message)
        case .retainedObservation: observeRetained(message)
        case .arming, .capturing, .committing, .interactive, .finishing: finish("unexpected_child_reply")
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

    private func waitForFocus(_ message: IsolationChildMessage) {
        let kind = stage == .selecting ? "selected" : "snapshot"
        guard message.kind == kind, pristine(message), message.fixtureSelectionUnchanged == true else {
            return finish("fixture_selection_unconfirmed")
        }
        pendingSnapshot = false
        guard message.active, message.focused, permitsFixturePost else {
            stage = .waitingFocus
            nextSnapshotAt = DispatchTime.now().uptimeNanoseconds + 50_000_000
            return
        }
        if mode == .control {
            guard let marker = markers?.challengeRelease,
                  postFixture(.init(marker: marker, keyCode: 0, down: false, text: "")) else {
                return finish("control_post_refused")
            }
            postedControl = 1
            beginObservation(.observing)
            return
        }
        stage = .arming
        Task { [weak self] in await self?.armAndCapture() }
    }

    private func armAndCapture() async {
        guard let owner, await owner.start(), !finished, pendingFinishReason == nil, permitsFixturePost,
              await owner.arm(), !finished, pendingFinishReason == nil, owner.captureIsCurrent,
              let markers else { return finish("capture_arm_refused") }
        guard postFixture(.init(marker: markers.prefixDown, keyCode: 0, down: true, text: "kept")) else {
            return finish("prefix_down_refused")
        }
        postedPrefix += 1
        guard owner.captureIsCurrent,
              postFixture(.init(marker: markers.prefixRelease, keyCode: 0, down: false, text: "kept")) else {
            return finish("prefix_release_refused")
        }
        postedPrefix += 1
        stage = .capturing
    }

    func checkCapturedPrefix() {
        guard let owner, owner.captureIsCurrent, permitsFixturePost else { return finish("capture_invalidated") }
        let report = owner.report
        guard report.capturedEvents <= 2, report.capturedUTF16Bytes <= 16 else {
            return finish("capture_count_invalid")
        }
        guard report.capturedEvents == 2, report.capturedUTF16Bytes == 16 else { return }
        stage = .committing
        Task { [weak self] in
            guard let self else { return }
            let result = await owner.commit(refuseWake: self.mode == .retain,
                                             permitsWake: { [weak self] in self?.permitsFixturePost == true })
            guard !self.finished, self.pendingFinishReason == nil else { return }
            if result == .completed, self.mode == .flush { self.beginObservation(.observing) } else if
                result == .retained, self.mode == .retain { self.beginObservation(.retainedObservation) } else {
                self.finish("ordinary_commit_\(result.rawValue)")
            }
        }
    }

    private func beginObservation(_ stage: RecoveryOrdinaryStage) {
        self.stage = stage
        observationStartedAt = DispatchTime.now().uptimeNanoseconds
        nextSnapshotAt = observationStartedAt ?? 0
        observedAt = nil
    }

    private func observeInitial(_ message: IsolationChildMessage) {
        guard validSnapshot(message) else { return finish("observation_invalid") }
        let matched: Bool
        if mode == .control {
            matched = message.fixtureTextUnchanged == true && message.fixtureSelectionUnchanged == true
                && message.changeCount == 0 && message.received == ["challengeRelease"]
                && message.ordinaryWakeReleaseObserved
        } else {
            matched = message.controlTextMatches && message.controlSelectionMatches && message.changeCount == 1
                && message.received == ["prefixDown", "prefixRelease"] && owner?.report.completed == true
                && !message.ordinaryWakeReleaseObserved
        }
        guard matched else { observedAt = nil; return }
        if mode == .control {
            if stableObservation() { observed = true; finish("wake_control_observed") }
            return
        }
        initialFlushObserved = true
        guard let markers,
              postFixture(.init(marker: markers.challengeDown, keyCode: 7, down: true, text: "x")) else {
            return finish("continuation_down_refused")
        }
        postedContinuation += 1
        guard postFixture(.init(marker: markers.prefixRelease, keyCode: 7, down: false, text: "x")) else {
            return finish("continuation_release_refused")
        }
        postedContinuation += 1
        beginObservation(.continuing)
    }

    private func observeContinuation(_ message: IsolationChildMessage) {
        guard validSnapshot(message) else { return finish("continuation_observation_invalid") }
        let labels = ["prefixDown", "prefixRelease", "challengeDown", "prefixRelease"]
        guard message.ordinaryContinuationTextMatches, message.ordinaryContinuationSelectionMatches,
              !message.ordinaryWakeReleaseObserved,
              message.changeCount == 2, message.received == labels else { observedAt = nil; return }
        if stableObservation() { observed = true; finish("ordinary_flush_and_continuation_observed") }
    }

    private func observeRetained(_ message: IsolationChildMessage) {
        guard validSnapshot(message), pristine(message), message.fixtureSelectionUnchanged == true,
              !message.ordinaryWakeReleaseObserved,
              let snapshot = owner?.report, snapshot.adopted, snapshot.ordinaryClaim, snapshot.claimCount == 1,
              snapshot.ledgerSubmissions == 0, snapshot.retainedEvents == 2, snapshot.retainedUTF16Bytes == 16,
              snapshot.delivery?.attemptedPosts == 0 else { return finish("retained_observation_invalid") }
        retainedObserved = true
        observed = true
        stage = .interactive
        status = "retained_ui_ready"
        showRecovery()
        report()
    }

    private func validSnapshot(_ message: IsolationChildMessage) -> Bool {
        pendingSnapshot = false
        return message.kind == "snapshot" && message.active && message.focused && permitsFixturePost
    }

    private func pristine(_ message: IsolationChildMessage) -> Bool {
        message.fixtureTextUnchanged == true && message.changeCount == 0 && message.received.isEmpty
    }

    private func stableObservation() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if observedAt == nil { observedAt = now }
        return observedAt.map { now - $0 >= 100_000_000 } ?? false
    }
}
#endif
