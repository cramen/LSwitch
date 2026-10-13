import CoreGraphics
import Foundation

/// Тип события клавиатуры, снятый с CGEvent для передачи между очередями.
public enum RawKeyEventType: Sendable, Equatable {
    case keyDown
    case keyUp
    case flagsChanged
    case other
}

/// Лёгкий снимок события клавиатуры. Callback event tap извлекает поля
/// в эту структуру и передаёт её дальше — сам CGEvent за пределы callback
/// не выносится.
public struct RawKeyEvent: Sendable, Equatable {
    public let type: RawKeyEventType
    public let keyCode: UInt16
    public let characters: String
    /// `CGEventFlags.rawValue` — сам тип CGEventFlags не объявлен Sendable.
    public let modifierFlags: UInt64
    /// Событие помечено как синтезированное самим LSwitch.
    public let isSynthetic: Bool
    /// `mach_absolute_time`-штамп события в наносекундах (как у CGEvent.timestamp).
    public let timestamp: UInt64

    public init(
        type: RawKeyEventType,
        keyCode: UInt16,
        characters: String,
        modifierFlags: UInt64,
        isSynthetic: Bool,
        timestamp: UInt64
    ) {
        self.type = type
        self.keyCode = keyCode
        self.characters = characters
        self.modifierFlags = modifierFlags
        self.isSynthetic = isSynthetic
        self.timestamp = timestamp
    }
}

/// Метка собственных синтезированных событий (design D2).
///
/// События, которые LSwitch сам вставляет в поток (Cmd+C/Cmd+V, ввод
/// сконвертированного текста), помечаются магическим значением в поле
/// `eventSourceUserData`. Перехватчик обязан такие события игнорировать,
/// чтобы не ловить собственную симуляцию.
///
/// Спайк P0.1 должен подтвердить, что поле доезжает от постинга до callback
/// без изменений; если нет — включается план B (подавление по очереди
/// ожидаемых событий).
public enum SyntheticEventMarker {

    /// "LSWTCH\x01" — маловероятное для случайного совпадения значение.
    public static let magic: Int64 = 0x4C53_5754_4348_0001

    /// Помечает событие как синтезированное LSwitch. Вызывать до постинга.
    public static func tag(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: magic)
    }

    public static func isSynthetic(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == magic
    }
}

/// Превращает событие клавиатуры в `Keystroke` для `KeystrokeBuffer`.
///
/// Чистая функция без системных вызовов — покрыта unit-тестами.
public struct KeystrokeClassifier: Sendable {

    /// Модификаторы, при которых нажатие считается командой, а не вводом текста.
    private static let commandMask: UInt64 =
        CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue

    /// Key code клавиш, сбрасывающих контекст слова (курсорные, Delete, Escape, Tab).
    private static let controlKeyCodes: Set<UInt16> = [
        48, // Tab
        51, // Delete (Backspace)
        53, // Escape
        117, // Forward Delete
        123, 124, 125, 126, // стрелки
        115, 119, 116, 121, // Home, End, PageUp, PageDown
    ]

    public init() {}

    /// Возвращает `nil`, если событие не относится к вводу текста
    /// (keyUp, flagsChanged, синтетика).
    public func classify(_ event: RawKeyEvent) -> Keystroke.Kind? {
        guard !event.isSynthetic, event.type == .keyDown else { return nil }
        if event.modifierFlags & Self.commandMask != 0 { return .control }
        if Self.controlKeyCodes.contains(event.keyCode) { return .control }
        guard let character = event.characters.first else { return nil }
        return classify(character: character)
    }

    public func classify(character: Character) -> Keystroke.Kind {
        if character == "\n" || character == "\r" { return .delimiter("\n") }
        if character == " " { return .delimiter(" ") }
        if character.isLetter || character.isNumber { return .character(character) }
        if LayoutMap.shared.layout(of: character) != nil { return .character(character) }
        if character.isPunctuation || character.isSymbol { return .delimiter(character) }
        return .control
    }
}
