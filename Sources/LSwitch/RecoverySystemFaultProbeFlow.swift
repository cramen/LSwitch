#if DEBUG
import AppKit
import CoreGraphics
import LSwitchCore

@MainActor
extension RecoverySystemFaultProbeController {
    func consumeMailbox() {
        guard let mailbox = peer.take() else { return }
        childExit = mailbox.exitStatus ?? childExit
        if let failure = mailbox.failure { finish(failure); return }
        for reply in mailbox.messages {
            guard !finished else { break }
            if reply.kind == "exiting" { childAborted = true; finish("child_aborted"); break }
            guard reply.sequence == expectedSequence, !reply.foreignInput, !reply.overflow else {
                finish("invalid_reply"); return
            }
            awaitingReply = false
            lastReply = reply
            handle(reply)
        }
        if mailbox.eof { childEOF = true; finish("unexpected_eof") }
    }

    private func handle(_ reply: IsolationChildMessage) {
        guard permitsForwardProgress else { return }
        switch phase {
        case .ready:
            configureChild(reply)
        case .configuring:
            guard reply.kind == "configured", pristine(reply) else { return finish("configure_invalid") }
            send(.selectFixture, next: .selecting)
        case .selecting, .waitingFocus: beginWhenFocused(reply)
        case .secureBefore, .secureAfter: observeSecure(reply)
        case .observingBefore, .observingAfter: observeResult(reply)
        case .stoppingSecure: finishSecure(reply)
        default: finish("unexpected_reply")
        }
    }

    private func configureChild(_ reply: IsolationChildMessage) {
        guard reply.kind == "ready", reply.windowTitle == "LSwitch Isolation Receiver \(peer.nonce)",
              let markers else { return finish("ready_invalid") }
        let values: [RecoveryIsolationLabel: Int64] = [.prefixDown: markers.prefixDown,
            .prefixRelease: markers.prefixRelease, .challengeDown: markers.challengeDown,
            .challengeRelease: markers.challengeRelease]
        guard let sequence = peer.send(.configure, markers: values) else { return finish("configure_failed") }
        expectedSequence = sequence
        awaitingReply = true
        phase = .configuring
    }


    private func beginWhenFocused(_ reply: IsolationChildMessage) {
        let expected = phase == .selecting ? "selected" : "snapshot"
        guard reply.kind == expected, pristine(reply), reply.fixtureSelectionUnchanged == true else {
            return finish("fixture_invalid")
        }
        guard reply.active, reply.focused, permitsPost else { phase = .waitingFocus; return }
        if mode == .control {
            guard postPair() else { return finish("control_post_refused") }
            phase = .observingBefore
            return
        }
        phase = .starting
        Task { [weak self] in await self?.startCandidate() }
    }

    private func startCandidate() async {
        guard permitsForwardProgress, let owner else { return }
        let result = await continuation.after({ await owner.start() }, then: {
            guard self.permitsPost else { return self.finish("driver_context_refused") }
            if self.mode == .secureBeforeArm { self.send(.secureInputOn, next: .secureBefore); return }
            if self.mode == .headBeforeArm {
                let disabled = await self.continuation.after({ await owner.disable(.head) }, then: {
                    guard self.permitsForwardProgress else { return }
                    self.beforeArmRefused = !owner.arm()
                    self.phase = .observingBefore
                })
                if disabled == .refused { self.finish("disable_unconfirmed") }
                return
            }
            guard self.permitsForwardProgress, owner.arm(), self.postPair() else {
                return self.finish("capture_refused")
            }
            self.phase = .capturing
        })
        if result == .refused { finish("driver_refused") }
    }

    func checkCaptured() {
        guard permitsForwardProgress else { return }
        guard let owner, permitsPost else { return finish("capture_context_lost") }
        let captured = owner.report.session
        guard captured.capturedEvents <= 2, captured.capturedUTF16Bytes <= 16 else {
            return finish("capture_overflow")
        }
        guard captured.capturedEvents == 2, captured.capturedUTF16Bytes == 16 else { return }
        if mode == .secureAfterCapture { send(.secureInputOn, next: .secureAfter); return }
        phase = .disabling
        Task { [weak self] in
            guard let self, self.permitsForwardProgress else { return }
            let result = await self.continuation.after({
                await owner.disable(self.mode == .tailAfterCapture ? .tail : .head)
            }, then: { await self.retireThenChallenge() })
            if result == .refused { self.finish("disable_unconfirmed") }
        }
    }

    private func observeSecure(_ reply: IsolationChildMessage) {
        guard permitsForwardProgress else { return }
        guard reply.kind == "secure_input", reply.active, reply.focused,
              reply.secure["enabled"] == true, reply.secure["owned"] == true,
              reply.secure["refused"] == false, reply.secureCounts["enable"] == 1,
              reply.secureCounts["disable"] == 0 else { return finish("secure_preflight_refused") }
        secureBalanced = false
        continuation.ifCurrent(after: { self.owner?.observeSecureInput(enabled: true) }, then: {
            guard self.permitsForwardProgress else { return }
            if self.phase == .secureBefore {
                self.beforeArmRefused = self.owner?.arm() == false
                self.send(.secureInputOff, next: .stoppingSecure)
            } else {
                Task { [weak self] in await self?.retireThenChallenge() }
            }
        })
    }

    private func retireThenChallenge() async {
        guard permitsForwardProgress, !retirementPending else { return }
        retirementPending = true
        defer { retirementPending = false }
        let result = await continuation.after({ await self.retainPrefix() }, then: {
            guard self.permitsPost, self.postPair(late: true) else {
                return self.finish("challenge_refused")
            }
            self.phase = .observingAfter
        })
        if result == .refused { finish("retirement_refused") }
    }

    private func observeResult(_ reply: IsolationChildMessage) {
        guard reply.kind == "snapshot", reply.active, reply.focused else { return finish("snapshot_invalid") }
        if mode == .control {
            guard reply.controlTextMatches, reply.controlSelectionMatches, reply.changeCount == 1,
                  reply.received == ["prefixDown", "prefixRelease"] else { return }
            observed = true
            finish("control_observed")
        } else if mode == .headBeforeArm {
            observed = beforeArmRefused && pristine(reply) && reply.fixtureSelectionUnchanged == true
            finish(observed ? "before_arm_refused" : "before_arm_inconclusive")
        } else {
            guard let report = owner?.report.session, report.storageOnlyAdopted,
                  report.capturedEvents == 2, report.capturedUTF16Bytes == 16, report.payloadCountReads == 2,
                  report.eventsRemaining == 2, report.utf16BytesRemaining == 16 else {
                return finish("retained_prefix_mismatch")
            }
            if mode == .secureAfterCapture {
                guard reply.secure["enabled"] == true, reply.secure["owned"] == true else {
                    return finish("secure_window_expired")
                }
                send(.secureInputOff, next: .stoppingSecure)
            } else { observed = true; showRetained() }
        }
    }

    private func finishSecure(_ reply: IsolationChildMessage) {
        guard reply.kind == "secure_input", reply.secure["owned"] == false,
              reply.secureCounts["enable"] == 1, reply.secureCounts["disable"] == 1 else {
            return finish("secure_cleanup_unconfirmed")
        }
        secureBalanced = true
        peer.cancelSecureWatchdog()
        observed = mode == .secureBeforeArm
            ? beforeArmRefused && pristine(reply) && reply.fixtureSelectionUnchanged == true
            : owner?.report.session.storageOnlyAdopted == true
        if mode == .secureBeforeArm { finish("secure_before_arm_observed") } else { showRetained() }
    }

    func showRetained() {
        phase = .interactive
        status = "retained_fixture_observed"
        reopenRecovery()
        report()
    }

    private func pristine(_ reply: IsolationChildMessage) -> Bool {
        reply.fixtureTextUnchanged == true && reply.changeCount == 0 && reply.received.isEmpty
    }

    var permitsPost: Bool {
        guard permitsForwardProgress else { return false }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let unsafe: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        let current = peer.isRunning && owner?.targetIsCurrent == true && flags.isDisjoint(with: unsafe)
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == peer.processID
        return current && permitsForwardProgress
    }

    private func postPair(late: Bool = false) -> Bool {
        guard let markers, let owner, permitsPost, let source = CGEventSource(stateID: .privateState),
              let pair = RecoveryDiagnosticPair<CGEvent>.prepare({ kind in
                  Self.makePacket(kind, source: source, markers: markers)
              }) else { return false }
        let originalPID = peer.processID
        let result = pair.dispatch(.init(canSubmit: { kind, event in
            self.permitsPost && self.peer.processID == originalPID && Self.packetMatches(event, kind, markers: markers)
        }, canBalance: { event in
            self.peer.isRunning && self.peer.processID == originalPID && owner.targetIsCurrent
                && Self.packetMatches(event, .release, markers: markers)
        }, post: { _, event in
            if late { self.postedLate += 1 } else { self.postedPrefix += 1 }
            if self.route == .hid { event.post(tap: .cghidEventTap) } else { event.postToPid(originalPID) }
        }, balance: { event in
            if late { self.postedLate += 1 } else { self.postedPrefix += 1 }
            event.postToPid(originalPID)
        }))
        guard let result else { return false }
        if result.balancingRelease { balancingReleases += 1 }
        keyboardDebtUnresolved = keyboardDebtUnresolved || result.unpostedDebt
        pairInconclusive = pairInconclusive || result.inconclusive
        return result.completed
    }

    private static func makePacket(
        _ kind: RecoveryDiagnosticPacketKind, source: CGEventSource, markers: RecoveryIsolationFixtureMarkers
    ) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: kind == .down) else {
            return nil
        }
        event.flags = []
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        let marker = kind == .down ? markers.prefixDown : markers.prefixRelease
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.keyboardSetUnicodeString(stringLength: 4, unicodeString: Array("kept".utf16))
        return packetMatches(event, kind, markers: markers) ? event : nil
    }

    private static func packetMatches(
        _ event: CGEvent, _ kind: RecoveryDiagnosticPacketKind, markers: RecoveryIsolationFixtureMarkers
    ) -> Bool {
        guard event.type == (kind == .down ? .keyDown : .keyUp), event.flags.isEmpty,
              event.getIntegerValueField(.keyboardEventKeycode) == 0,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()),
              event.getIntegerValueField(.eventSourceUserData)
                == (kind == .down ? markers.prefixDown : markers.prefixRelease) else { return false }
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length == 4 else { return false }
        var units = [UInt16](repeating: 0, count: 4)
        var actual = 0
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &actual, unicodeString: &units)
        return actual == 4 && units == Array("kept".utf16)
    }

}
#endif
