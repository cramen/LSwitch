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
        let commandMask = CGEventFlags.maskCommand.rawValue
            | CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        guard from != target, startedAt <= completedAt,
              event.type == .keyDown, !event.isSynthetic, !event.characters.isEmpty,
              event.modifierFlags & commandMask == 0,
              event.timestamp >= startedAt, event.timestamp <= completedAt else { return event }
        let text = LayoutMap.shared.convert(event.characters, from: from, to: target)
        guard text != event.characters else { return event }
        return RawKeyEvent(
            type: event.type, keyCode: event.keyCode, characters: text,
            modifierFlags: event.modifierFlags, isSynthetic: event.isSynthetic, timestamp: event.timestamp
        )
    }
}
