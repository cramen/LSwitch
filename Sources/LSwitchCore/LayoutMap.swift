import Foundation

/// Раскладка клавиатуры.
public enum Layout: String, CaseIterable, Sendable {
    case english = "en"
    case russian = "ru"

    public var opposite: Layout {
        switch self {
        case .english: return .russian
        case .russian: return .english
        }
    }
}

/// Двунаправленная таблица соответствия символов QWERTY ↔ ЙЦУКЕН.
///
/// Охватывает буквы (оба регистра), цифровой ряд со Shift
/// и пунктуацию стандартной русской раскладки.
public struct LayoutMap: Sendable {

    public static let shared = LayoutMap()

    private let enToRu: [Character: Character]
    private let ruToEn: [Character: Character]

    public init() {
        // Пары «английский символ — русский символ» на одной клавише.
        let pairs: [(Character, Character)] = [
            // Буквенный ряд 1
            ("q", "й"), ("w", "ц"), ("e", "у"), ("r", "к"), ("t", "е"),
            ("y", "н"), ("u", "г"), ("i", "ш"), ("o", "щ"), ("p", "з"),
            ("[", "х"), ("]", "ъ"), ("{", "Х"), ("}", "Ъ"),
            // Буквенный ряд 2
            ("a", "ф"), ("s", "ы"), ("d", "в"), ("f", "а"), ("g", "п"),
            ("h", "р"), ("j", "о"), ("k", "л"), ("l", "д"),
            (";", "ж"), ("'", "э"), (":", "Ж"), ("\"", "Э"),
            // Буквенный ряд 3
            ("z", "я"), ("x", "ч"), ("c", "с"), ("v", "м"), ("b", "и"),
            ("n", "т"), ("m", "ь"),
            (",", "б"), (".", "ю"), ("<", "Б"), (">", "Ю"),
            // Ё и пунктуация русской раскладки
            ("`", "ё"), ("~", "Ё"),
            ("/", "."), ("?", ","),
            // Цифровой ряд со Shift (русская раскладка)
            ("@", "\""), ("#", "№"), ("$", ";"), ("^", ":"), ("&", "?")
        ]

        var enToRu: [Character: Character] = [:]
        var ruToEn: [Character: Character] = [:]
        for (english, russian) in pairs {
            enToRu[english] = russian
            ruToEn[russian] = english
            // Регистры для букв. Обе стороны обязаны меняться в верхний регистр:
            // иначе для пунктуационных клавиш ("]"→"ъ") верхний регистр en
            // совпадает с исходным символом и затирает базовую пару.
            let englishUpper = Character(english.uppercased())
            let russianUpper = Character(russian.uppercased())
            if englishUpper != english, russianUpper != russian {
                enToRu[englishUpper] = russianUpper
                ruToEn[russianUpper] = englishUpper
            }
        }
        self.enToRu = enToRu
        self.ruToEn = ruToEn
    }

    /// Конвертирует строку из раскладки `from` в раскладку `to`.
    /// Символы без соответствия (пробелы, цифры, unicode) сохраняются как есть.
    public func convert(_ text: String, from: Layout, to target: Layout) -> String {
        precondition(from != target, "Раскладки должны отличаться")
        let table = (from == .english) ? enToRu : ruToEn
        return String(text.map { table[$0] ?? $0 })
    }

    /// Конвертирует строку «наоборот»: каждый символ переводится
    /// в противоположную раскладку, если соответствие существует.
    public func invert(_ text: String) -> String {
        String(text.map { enToRu[$0] ?? ruToEn[$0] ?? $0 })
    }

    /// Определяет, какой раскладке соответствует символ (если соответствие есть).
    public func layout(of char: Character) -> Layout? {
        if ruToEn[char] != nil { return .russian }
        if enToRu[char] != nil { return .english }
        return nil
    }
}
