import CoreGraphics
import Foundation

/// Физическая клавиша не зависит от текущей раскладки. nil означает двойной Shift.
public struct ConversionHotkey: Codable, Equatable, Sendable {
    public let keyCode: UInt16?
    public let modifiers: UInt64
    public static let doubleShift = ConversionHotkey(keyCode: nil, modifiers: 0)
    public static let modifierMask = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue

    public init(keyCode: UInt16?, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var isValid: Bool {
        guard let keyCode else { return modifiers == 0 }
        let command = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
        return Self.keys.contains { $0.code == keyCode } && modifiers & command != 0
            && modifiers & ~Self.modifierMask == 0
    }

    public var title: String {
        guard let keyCode else { return "Двойной Shift" }
        let prefix = [(CGEventFlags.maskControl, "⌃"), (.maskAlternate, "⌥"),
                      (.maskShift, "⇧"), (.maskCommand, "⌘")]
            .filter { modifiers & $0.0.rawValue != 0 }.map { $0.1 }.joined()
        return prefix + (Self.keys.first { $0.code == keyCode }?.label ?? "?")
    }

    public struct Key: Identifiable, Sendable {
        public let code: UInt16
        public let label: String
        public var id: UInt16 { code }
    }

    public static let keys: [Key] = {
        let letters: [(UInt16, String)] = [
            (0, "A"), (11, "B"), (8, "C"), (2, "D"), (14, "E"), (3, "F"), (5, "G"), (4, "H"),
            (34, "I"), (38, "J"), (40, "K"), (37, "L"), (46, "M"), (45, "N"), (31, "O"), (35, "P"),
            (12, "Q"), (15, "R"), (1, "S"), (17, "T"), (32, "U"), (9, "V"), (13, "W"), (7, "X"),
            (16, "Y"), (6, "Z"), (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"),
            (22, "6"), (26, "7"), (28, "8"), (25, "9"), (122, "F1"), (120, "F2"), (99, "F3"),
            (118, "F4"), (96, "F5"), (97, "F6"), (98, "F7"), (100, "F8"), (101, "F9"),
            (109, "F10"), (103, "F11"), (111, "F12")
        ]
        return letters.map { Key(code: $0.0, label: $0.1) }
    }()
}

public struct ConversionHotkeyDetector {
    public enum Result { case none, trigger, consumed }
    private var doubleShift = DoubleShiftDetector()
    private var pressed = Set<UInt16>()
    private var configuration = ConversionHotkey.doubleShift

    public init() {}

    /// Reset контекста не превращает autorepeat удерживаемой клавиши в новое нажатие.
    public mutating func resetSequence() { doubleShift = DoubleShiftDetector() }

    public mutating func handle(_ event: RawKeyEvent, hotkey: ConversionHotkey) -> Result {
        guard !event.isSynthetic else { return .none }
        if configuration != hotkey { configuration = hotkey; resetSequence() }
        if event.type == .keyUp { pressed.remove(event.keyCode); return .none }
        let firstDown = event.type == .keyDown ? pressed.insert(event.keyCode).inserted : false
        guard let keyCode = hotkey.keyCode else { return doubleShift.handle(event) ? .trigger : .none }
        guard hotkey.isValid, event.type == .keyDown, event.keyCode == keyCode,
              event.modifierFlags & ConversionHotkey.modifierMask == hotkey.modifiers else { return .none }
        return firstDown ? .trigger : .consumed
    }
}
