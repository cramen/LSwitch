#if DEBUG
import AppKit
import CoreGraphics

struct RecoveryOrdinaryFixturePacket {
    let marker: Int64
    let keyCode: UInt16
    let down: Bool
    let text: String
}

@MainActor
extension RecoveryOrdinaryProbeController {
    var permitsFixturePost: Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let unsafe: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]
        return !finished && pendingFinishReason == nil && peer.isRunning && owner?.targetIsCurrent == true
            && NSWorkspace.shared.frontmostApplication?.processIdentifier == peer.processID
            && flags.isDisjoint(with: unsafe)
    }

    func postFixture(_ packet: RecoveryOrdinaryFixturePacket) -> Bool {
        guard permitsFixturePost, let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: packet.keyCode, keyDown: packet.down) else {
            return false
        }
        event.flags = []
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.setIntegerValueField(.eventSourceUserData, value: packet.marker)
        let units = Array(packet.text.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()),
              event.getIntegerValueField(.eventSourceUserData) == packet.marker,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(packet.keyCode),
              event.type == (packet.down ? .keyDown : .keyUp), event.flags.isEmpty,
              permitsFixturePost else { return false }
        event.postToPid(peer.processID)
        return true
    }
}
#endif
