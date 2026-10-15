import CoreGraphics
import Foundation
import os

#if DEBUG
/// Диагностирует только создаваемые LSwitch Copy/Paste; не получает пользовательские события.
enum CommandUnicodeDiagnostics {
    enum Category: String { case latin, mapped, empty, other }

    private static let logger = Logger(subsystem: "LSwitch", category: "Keyboard")

    static func category(units: [UInt16], command: ClipboardCommand) -> Category? {
        guard let latin = latinLetter(for: command) else { return nil }
        guard !units.isEmpty else { return .empty }
        let value = String(decoding: units, as: UTF16.self).lowercased()
        if value == latin { return .latin }
        let mapped = LayoutMap.shared.convert(latin, from: .english, to: .russian)
        return value == mapped ? .mapped : .other
    }

    @MainActor
    static func record(command: ClipboardCommand, events: [CGEvent]) {
        guard latinLetter(for: command) != nil,
              let down = events.first(where: { $0.type == .keyDown }),
              SyntheticEventMarker.isSynthetic(down) else { return }
        var count = 0
        down.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
        // Даже собственное событие читается ограниченно; неизвестное представление остаётся other.
        var units = [UInt16](repeating: 0, count: min(count, 8))
        var readCount = 0
        down.keyboardGetUnicodeString(
            maxStringLength: units.count, actualStringLength: &readCount, unicodeString: &units
        )
        let native = count == readCount ? category(units: units, command: command) ?? .other : .other
        let layout = LayoutManager().currentLayout()?.rawValue ?? "unknown"
        let label = command == .copy ? "copy" : "paste"
        let description = "command=\(label) nativeUnicode=\(native.rawValue) units=\(count) tisLayout=\(layout)"
        logger.info("\(description, privacy: .public)")
    }

    private static func latinLetter(for command: ClipboardCommand) -> String? {
        switch command {
        case .copy: return "c"
        case .paste: return "v"
        default: return nil
        }
    }
}
#endif
