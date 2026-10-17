#if DEBUG
import CoreGraphics
import Darwin
import Foundation

/// Только metadata wake-control. KeyUp 0 ещё требует отдельного live control и не объявляется нейтральным.
struct RecipientOrdinaryMarker: Equatable, Sendable {
    let sourcePID: Int32
    let value: Int64

    init?(sourcePID: Int32, diagnosticValue: Int64? = nil) {
        guard sourcePID > 0, let value = diagnosticValue ?? NativeDispatchMarkers.shared?.reserve(1)?.first,
              value > 0, value < 1 << 52, value != SyntheticEventMarker.magic else { return nil }
        self.sourcePID = sourcePID
        self.value = value
    }

    func owns(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(sourcePID)
            && event.getIntegerValueField(.eventSourceUserData) == value
    }

    func matches(type: CGEventType, event: CGEvent) -> Bool {
        owns(event) && type == .keyUp && event.type == type
            && event.getIntegerValueField(.keyboardEventKeycode) == 0
            && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
            && event.flags.subtracting(.maskNonCoalesced).isEmpty
    }

    @MainActor
    func prepareEvent() -> CGEvent? {
        guard sourcePID == getpid(), let source = CGEventSource(stateID: .privateState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return nil }
        event.flags = []
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.setIntegerValueField(.eventSourceUserData, value: value)
        event.keyboardSetUnicodeString(stringLength: 0, unicodeString: [])
        return matches(type: .keyUp, event: event) ? event : nil
    }
}

/// Коррекция меняет только созданную custody копию; неизвестный UTF-16 не нормализуется молча.
enum RecipientOrdinaryCorrection {
    static func prepare(_ event: CGEvent, transition: ConversionRecoveryLayoutTransition?) -> Bool {
        guard let transition, event.type == .keyDown, transition.source != transition.target,
              transition.startedAt <= event.timestamp, event.timestamp <= transition.completedAt else { return true }
        guard QueuedInputCorrection.permitsTextModifiers(event.flags.rawValue) else {
            return QueuedInputCorrection.preservesKnownShortcut(event.flags.rawValue)
        }
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
        guard count >= 0, count <= PreparedRecoveryAdmission.maximumUTF16Bytes / 2 else { return false }
        var units = [UniChar](repeating: 0, count: count)
        var actual = 0
        event.keyboardGetUnicodeString(maxStringLength: count, actualStringLength: &actual, unicodeString: &units)
        guard actual == count else { return false }
        let text = String(decoding: units, as: UTF16.self)
        guard text.utf16.elementsEqual(units) else { return false }
        let converted = LayoutMap.shared.convert(text, from: transition.source, to: transition.target)
        let replacement = Array(converted.utf16)
        event.keyboardSetUnicodeString(stringLength: replacement.count, unicodeString: replacement)
        var verified = [UniChar](repeating: 0, count: replacement.count)
        event.keyboardGetUnicodeString(maxStringLength: replacement.count,
                                      actualStringLength: &actual, unicodeString: &verified)
        return actual == replacement.count && verified == replacement
    }
}
#endif
