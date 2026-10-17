import CoreGraphics
import Foundation

/// Исправляет Unicode уже ожидавших клавиш после подтверждённой смены раскладки.
/// Время задаётся в наносекундах uptime, как CGEvent.timestamp и DispatchTime.
struct QueuedInputCorrection: Sendable {
    let from: Layout
    let target: Layout
    let startedAt: UInt64
    let completedAt: UInt64

    init(from: Layout, to target: Layout, startedAt: UInt64, completedAt: UInt64) {
        self.from = from
        self.target = target
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    func corrected(_ event: RawKeyEvent) -> RawKeyEvent {
        // Совместимость обычного EventTapCore: прежний generic Cmd/Ctrl/Option фильтр.
        let commandMask = CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        return corrected(event, modifiersPermitted: event.modifierFlags & commandMask == 0)
    }

    /// Только tracked logical tail; native transport отдельно отказывает до post при неизвестных flags.
    func correctedTracked(_ event: RawKeyEvent) -> RawKeyEvent {
        corrected(event, modifiersPermitted: Self.permitsTextModifiers(event.modifierFlags))
    }

    private func corrected(_ event: RawKeyEvent, modifiersPermitted: Bool) -> RawKeyEvent {
        guard from != target, startedAt <= completedAt,
              event.type == .keyDown, !event.isSynthetic, !event.characters.isEmpty,
              modifiersPermitted,
              event.timestamp >= startedAt, event.timestamp <= completedAt else { return event }
        let text = LayoutMap.shared.convert(event.characters, from: from, to: target)
        guard text != event.characters else { return event }
        return RawKeyEvent(
            type: event.type, keyCode: event.keyCode, characters: text,
            modifierFlags: event.modifierFlags, isSynthetic: event.isSynthetic, timestamp: event.timestamp
        )
    }

    /// Только Shift/Caps и известные metadata bits. Device-only shortcut не становится обычным текстом.
    static func permitsTextModifiers(_ flags: UInt64) -> Bool { flags & ~textModifierBits == 0 }

    static func preservesKnownShortcut(_ flags: UInt64) -> Bool {
        flags & shortcutModifierBits != 0 && flags & ~(textModifierBits | shortcutModifierBits) == 0
    }

    private static let shortcutModifierBits = [
        CGEventFlags.maskCommand, .maskControl, .maskAlternate
    ].reduce(UInt64(0)) { $0 | $1.rawValue } | 0x0000_2079

    private static let textModifierBits: UInt64 = [
        CGEventFlags.maskShift, .maskAlphaShift, .maskNumericPad, .maskNonCoalesced
    ].reduce(UInt64(0)) { $0 | $1.rawValue } | 0x0100_0086
}
