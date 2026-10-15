import Foundation

/// Начальный набор намеренно уже BMP: каждый пакет проверяется целиком до выделения.
enum UnicodePacketPolicy {
    static let maximumUnits = 32
    private static let bidirectional = try? NSRegularExpression(pattern: "[\\p{bc=R}\\p{bc=AL}\\p{Bidi_Control}]")

    static func permits(_ text: String) -> Bool {
        permits(units: Array(text.utf16.prefix(maximumUnits + 1)))
    }

    static func permits(units: [UInt16]) -> Bool {
        guard !units.isEmpty, units.count <= maximumUnits else { return false }
        return units.allSatisfy { unit in
            switch unit {
            case 0x20...0x7E, 0x00A0, 0x0410...0x044F, 0x0401, 0x0451: return true
            default: return false
            }
        }
    }

    static func permitsSelection(in text: String, range: NSRange) -> Bool {
        let source = text as NSString
        guard range.location >= 0, range.length > 0, range.location <= source.length,
              range.length <= source.length - range.location,
              Range(range, in: text) != nil, source.rangeOfComposedCharacterSequences(for: range) == range,
              let bidirectional else { return false }
        return bidirectional.firstMatch(in: text, range: source.lineRange(for: range)) == nil
    }
}
