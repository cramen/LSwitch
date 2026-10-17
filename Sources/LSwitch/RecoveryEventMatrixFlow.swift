#if DEBUG
import AppKit
import CoreGraphics
import LSwitchCore

private struct MatrixKeyboardPacket {
    let type: CGEventType
    let code: UInt16
    let flags: CGEventFlags
    let marker: Int64
}

private struct PreparedMatrixKeyboardPacket {
    let event: CGEvent
    let shape: MatrixKeyboardPacket

    var isUnchanged: Bool {
        event.type == shape.type && event.flags == shape.flags
            && event.getIntegerValueField(.keyboardEventKeycode) == Int64(shape.code)
            && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
            && event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
            && event.getIntegerValueField(.eventSourceUserData) == shape.marker
    }
}

@MainActor
extension RecoveryEventMatrixController {
    func consumeMailbox() {
        guard let mailbox = peer.take() else { return }
        childStderr = mailbox.stderrBytes
        childExit = mailbox.exitStatus ?? childExit
        if let failure = mailbox.failure { finish(failure); return }
        for message in mailbox.messages {
            guard !finished else { break }
            handle(message)
        }
        if mailbox.eof, !finished { finish("unexpected_child_eof") }
    }

    func handle(_ message: IsolationChildMessage) {
        guard message.sequence == expectedSequence, !message.foreignInput, !message.overflow,
              message.kind != "exiting" else { return finish("child_reply_invalid") }
        lastReply = message
        switch stage {
        case .ready: configure(message)
        case .configuring:
            guard message.kind == "configured", message.fixtureTextUnchanged == true,
                  let sequence = peer.send(.armEventMatrix) else { return finish("arm_failed") }
            expectedSequence = sequence
            stage = .arming
        case .arming:
            guard message.kind == "matrix_armed", message.matrixArmed, message.active, message.focused,
                  hasChildFocus else { return finish("armed_focus_invalid") }
            stage = .preparing
            Task { await prepareGateAndSend() }
        case .observing, .interactive:
            guard message.kind == "snapshot", message.matrixArmed else { return finish("snapshot_invalid") }
            pendingSnapshot = false
            stage = .interactive
            status = "interactive_ready"
            report()
            if keyboardOnly { finish("keyboard_observation_complete") } else if finishingAfterSnapshot {
                finish("operator_finished")
            }
        case .preparing, .finishing: finish("unexpected_reply")
        }
    }

    private func configure(_ message: IsolationChildMessage) {
        guard message.kind == "ready", message.windowTitle == "LSwitch Isolation Receiver \(peer.nonce)",
              message.fixtureTextUnchanged == true, message.changeCount == 0, let markers else {
            return finish("child_ready_invalid")
        }
        let values: [RecoveryIsolationLabel: Int64] = [
            .prefixDown: markers.prefixDown, .prefixRelease: markers.prefixRelease,
            .challengeDown: markers.challengeDown, .challengeRelease: markers.challengeRelease
        ]
        guard let sequence = peer.send(.configure, markers: values) else { return finish("configure_failed") }
        expectedSequence = sequence
        stage = .configuring
    }

    private func prepareGateAndSend() async {
        if mode != .control {
            guard let anchor, let driver = RecipientTapDriver(bridge: anchor.bridge) else {
                return finish("driver_unavailable")
            }
            self.driver = driver
            guard await driver.start(), !finished, hasChildFocus,
                  driver.activateProtection() else { return finish("prearm_failed") }
            if mode == .closed { driver.closeGeneration() }
            if mode == .lost { driver.markPeerEOF() }
        }
        guard !finished, sendKeyboardControl() else { return finish("keyboard_control_failed") }
        stage = .observing
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            self?.requestSnapshot()
        }
    }

    private var hasChildFocus: Bool {
        !finished && hasChildIdentity
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == peer.processID
    }

    private var hasChildIdentity: Bool { peer.isRunning && anchor?.targetIsCurrent == true }

    /// Только известный Cmd+A в собственный nonce-bound child; clipboard и произвольный текст не используются.
    private func sendKeyboardControl() -> Bool {
        guard let events = preparedKeyboardControl() else { return false }
        var modifierDebt = false
        var keyDebt = false
        defer {
            if keyDebt, hasChildIdentity, events[2].isUnchanged {
                events[2].event.postToPid(peer.processID)
                balancingReleases += 1
                keyDebt = false
            }
            if modifierDebt, hasChildIdentity, events[3].isUnchanged {
                events[3].event.postToPid(peer.processID)
                balancingReleases += 1
                modifierDebt = false
            }
            keyboardDebtUnresolved = keyDebt || modifierDebt
        }
        for (index, prepared) in events.enumerated() {
            guard hasChildFocus, prepared.isUnchanged else { return false }
            let event = prepared.event
            if keyboardRoute == .recipient { event.postToPid(peer.processID) } else {
                event.post(tap: .cgSessionEventTap)
            }
            postedCount += 1
            switch index {
            case 0: modifierDebt = true
            case 1: keyDebt = true
            case 2: keyDebt = false
            case 3: modifierDebt = false
            default: return false
            }
        }
        return true
    }

    private func preparedKeyboardControl() -> [PreparedMatrixKeyboardPacket]? {
        guard let markers, let source = CGEventSource(stateID: .privateState) else { return nil }
        let packets: [MatrixKeyboardPacket] = [
            .init(type: .flagsChanged, code: 55, flags: .maskCommand, marker: markers.prefixDown),
            .init(type: .keyDown, code: 0, flags: .maskCommand, marker: markers.challengeDown),
            .init(type: .keyUp, code: 0, flags: .maskCommand, marker: markers.challengeRelease),
            .init(type: .flagsChanged, code: 55, flags: [], marker: markers.prefixRelease)
        ]
        var events: [PreparedMatrixKeyboardPacket] = []
        for packet in packets {
            guard hasChildFocus, let event = CGEvent(keyboardEventSource: source, virtualKey: packet.code,
                                      keyDown: packet.type == .keyDown) else { return nil }
            event.type = packet.type
            event.flags = packet.flags
            // Командная клавиша сохраняет нативный Unicode, как рабочий KeyboardEmitter.
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
            event.setIntegerValueField(.eventSourceUserData, value: packet.marker)
            guard event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()),
                  event.getIntegerValueField(.eventSourceUserData) == packet.marker,
                  event.type == packet.type, event.flags == packet.flags else { return nil }
            events.append(.init(event: event, shape: packet))
        }
        return events
    }
}
#endif
