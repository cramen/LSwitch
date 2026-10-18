import CoreGraphics

extension NativeDispatchShape {
    /// Только header собственных пакетов. Payload и состояние физической клавиатуры не читаются.
    static func readKeyboard(_ event: CGEvent) -> Self? {
        guard let keyCode = UInt16(exactly: event.getIntegerValueField(.keyboardEventKeycode)) else { return nil }
        let phase: NativeDispatchPhase
        switch event.type {
        case .keyDown: phase = .keyDown
        case .keyUp: phase = .keyUp
        case .flagsChanged:
            guard let flag = modifierFlag(keyCode) else { return nil }
            phase = event.flags.contains(flag) ? .modifierDown : .modifierUp
        default: return nil
        }
        return .init(phase: phase, keyCode: keyCode, modifierFlags: event.flags.rawValue)
    }

    private static func modifierFlag(_ keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        default: return nil
        }
    }
}
