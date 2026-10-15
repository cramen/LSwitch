import Foundation

enum LayoutObservationStage: String, Sendable { case alreadyTarget, adapter, readback }

#if DEBUG
/// Только категории: исходный текст receipt не сохраняется даже в DEBUG metadata.
struct ConversionLayoutMetadata: Equatable, Sendable {
    enum Alphabet: String, Sendable { case english = "en", russian = "ru", mixed, unknown }

    let source: Layout
    let target: Layout
    let original: Alphabet
    let converted: Alphabet
    var stage = "decision"
    var accepted: Bool?
    var observed: Layout?

    var logFields: String {
        " sourceLayout=\(source.rawValue) targetLayout=\(target.rawValue)"
            + " originalAlphabet=\(original.rawValue) convertedAlphabet=\(converted.rawValue)"
            + " layoutStage=\(stage) adapterAccepted=\(accepted.map(String.init) ?? "not-called")"
            + " observedLayout=\(observed?.rawValue ?? "unavailable")"
    }

    static func alphabet(_ text: String) -> Alphabet {
        var english = false
        var russian = false
        var unsupported = false
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            switch scalar.value {
            case 65...90, 97...122: english = true
            case 0x0410...0x044F, 0x0401, 0x0451: russian = true
            default: unsupported = true
            }
        }
        if unsupported { return .unknown }
        if english && russian { return .mixed }
        if english { return .english }
        if russian { return .russian }
        return .unknown
    }
}
#endif
