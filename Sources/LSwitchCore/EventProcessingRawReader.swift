import CoreGraphics
import Foundation

/// Только bounded локальные CGEvent getters. Нет AX/TIS/IO, коррекции или изменения исходного события.
enum EventProcessingRawReader {
    enum Result {
        case event(RawKeyEvent, units: Int, payloadRead: Bool)
        case failure(EventProcessingInvalidation, payloadRead: Bool)
    }

    static func read(type: CGEventType, event: CGEvent, remainingUnits: Int) -> Result {
        guard event.type == type,
              let code = UInt16(exactly: event.getIntegerValueField(.keyboardEventKeycode)) else {
            return .failure(.invalidPayload, payloadRead: false)
        }
        var text = ""
        var unitsRead = 0
        let rawType: RawKeyEventType
        switch type {
        case .keyDown:
            rawType = .keyDown
            var count = 0
            event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
            guard count >= 0 else { return .failure(.invalidPayload, payloadRead: true) }
            guard count <= remainingUnits else { return .failure(.payloadLimit, payloadRead: true) }
            if count > 0 {
                var units = [UniChar](repeating: 0, count: count)
                var actual = 0
                event.keyboardGetUnicodeString(
                    maxStringLength: count, actualStringLength: &actual, unicodeString: &units)
                var rechecked = 0
                event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &rechecked, unicodeString: nil)
                guard let decoded = decode(units, expected: count, actual: actual, rechecked: rechecked) else {
                    return .failure(.invalidPayload, payloadRead: true)
                }
                text = decoded
            }
            unitsRead = count
        case .keyUp: rawType = .keyUp
        case .flagsChanged: rawType = .flagsChanged
        default: rawType = .other
        }
        let raw = RawKeyEvent(type: rawType, keyCode: code, characters: text, modifierFlags: event.flags.rawValue,
                              isSynthetic: SyntheticEventMarker.isSynthetic(event), timestamp: event.timestamp)
        return .event(raw, units: unitsRead, payloadRead: type == .keyDown)
    }

    static func decode(_ units: [UInt16], expected: Int, actual: Int, rechecked: Int) -> String? {
        guard expected >= 0, units.count == expected, actual == expected, rechecked == expected else { return nil }
        let text = String(decoding: units, as: UTF16.self)
        return text.utf16.elementsEqual(units) ? text : nil
    }
}
