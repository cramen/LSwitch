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
        guard let kind = Self.typeMapping[eventType] else { return nil }
        self = kind
    }

    private static let typeMapping: [CGEventType: RecipientEventKind] = [
        .keyDown: .keyDown, .keyUp: .keyRelease, .flagsChanged: .modifierChange,
        .leftMouseDown: .leftMouseDown, .leftMouseUp: .leftMouseRelease, .leftMouseDragged: .leftMouseDrag,
        .rightMouseDown: .rightMouseDown, .rightMouseUp: .rightMouseRelease, .rightMouseDragged: .rightMouseDrag,
        .otherMouseDown: .otherMouseDown, .otherMouseUp: .otherMouseRelease, .otherMouseDragged: .otherMouseDrag,
        .scrollWheel: .scroll
    ]

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
    // Device-биты соответствуют NX_DEVICE*KEYMASK из SDK IOLLEvent.h и тоже обязаны сняться.
    private static let changedMasks: [Int64: CGEventFlags] = [
        54: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10),
        55: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08),
        56: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x02),
        60: CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x04),
        57: CGEventFlags(rawValue: CGEventFlags.maskAlphaShift.rawValue | 0x0100_0080),
        58: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20),
        61: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40),
        59: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x01),
        62: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000),
        63: .maskSecondaryFn
    ]

    static func tracked(_ flags: CGEventFlags) -> CGEventFlags { flags.subtracting(metadataMask) }

    /// Generic Shift остаётся включённым при отпускании одной стороны: такой случай не считаем release.
    static func isClearing(keyCode: Int64, flags: CGEventFlags, forwarded: CGEventFlags) -> Bool {
        guard let changed = changedMasks[keyCode] else { return false }
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
