#if DEBUG
import CoreGraphics
import Foundation

/// Фиксированный список типов, без текста, координат и произвольных keyboard payload.
public enum RecipientEventKind: String, CaseIterable, Sendable {
    case keyDown, keyRelease, modifierChange
    case leftMouseDown, leftMouseRelease, leftMouseDrag
    case rightMouseDown, rightMouseRelease, rightMouseDrag
    case otherMouseDown, otherMouseRelease, otherMouseDrag
    case scroll

    public init?(eventType: CGEventType) {
        switch eventType {
        case .keyDown: self = .keyDown
        case .keyUp: self = .keyRelease
        case .flagsChanged: self = .modifierChange
        case .leftMouseDown: self = .leftMouseDown
        case .leftMouseUp: self = .leftMouseRelease
        case .leftMouseDragged: self = .leftMouseDrag
        case .rightMouseDown: self = .rightMouseDown
        case .rightMouseUp: self = .rightMouseRelease
        case .rightMouseDragged: self = .rightMouseDrag
        case .otherMouseDown: self = .otherMouseDown
        case .otherMouseUp: self = .otherMouseRelease
        case .otherMouseDragged: self = .otherMouseDrag
        case .scrollWheel: self = .scroll
        default: return nil
        }
    }

    static let eventTypes: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel
    ]

    var mouseButton: Int? {
        switch self {
        case .leftMouseDown, .leftMouseRelease, .leftMouseDrag: return 0
        case .rightMouseDown, .rightMouseRelease, .rightMouseDrag: return 1
        case .otherMouseDown, .otherMouseRelease, .otherMouseDrag: return 2
        default: return nil
        }
    }

    var isMouseDown: Bool { self == .leftMouseDown || self == .rightMouseDown || self == .otherMouseDown }
    var isMouseRelease: Bool {
        self == .leftMouseRelease || self == .rightMouseRelease || self == .otherMouseRelease
    }

    func checkedButtonNumber(_ raw: Int64) -> Int? {
        guard let expected = mouseButton, let button = Int(exactly: raw), (0..<32).contains(button) else { return nil }
        return (expected == 2 ? button >= 2 : button == expected) ? button : nil
    }
}

enum RecipientModifierChange {
    private static let metadataMask: CGEventFlags = [.maskNumericPad, .maskNonCoalesced]

    static func tracked(_ flags: CGEventFlags) -> CGEventFlags { flags.subtracting(metadataMask) }

    /// Generic Shift остаётся включённым при отпускании одной стороны: такой случай не считаем release.
    static func isClearing(keyCode: Int64, flags: CGEventFlags, forwarded: CGEventFlags) -> Bool {
        // Device-биты соответствуют NX_DEVICE*KEYMASK из SDK IOLLEvent.h и тоже обязаны сняться.
        let changed: CGEventFlags
        switch keyCode {
        case 54: changed = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        case 55: changed = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
        case 56: changed = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x02)
        case 60: changed = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x04)
        case 57: changed = CGEventFlags(rawValue: CGEventFlags.maskAlphaShift.rawValue | 0x0100_0080)
        case 58: changed = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        case 61: changed = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        case 59: changed = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x01)
        case 62: changed = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)
        case 63: changed = .maskSecondaryFn
        default: return false
        }
        let current = tracked(flags)
        return current.isDisjoint(with: changed) && current.subtracting(tracked(forwarded)).isEmpty
    }
}

public struct RecipientEventCounters: Sendable {
    public let allowed: [Int]
    public let blocked: [Int]
    public let tail: [Int]
    public let captured: [Int]
}
#endif
