import Carbon
import Foundation

/// Проверяется активный input source, а не underlying layout активного IME.
struct UnicodeInputSource: Equatable, Sendable {
    let identifier: String
    let layout: Layout

    init?(identifier: String, isKeyboardLayout: Bool) {
        guard isKeyboardLayout else { return nil }
        switch identifier {
        case "com.apple.keylayout.ABC", "com.apple.keylayout.US": layout = .english
        case "com.apple.keylayout.Russian": layout = .russian
        default: return nil
        }
        self.identifier = identifier
    }

    @MainActor
    static func current() -> UnicodeInputSource? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let identifier = string(source, key: kTISPropertyInputSourceID),
              let type = string(source, key: kTISPropertyInputSourceType) else { return nil }
        return UnicodeInputSource(identifier: identifier, isKeyboardLayout: type == kTISTypeKeyboardLayout as String)
    }

    private static func string(_ source: TISInputSource, key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
