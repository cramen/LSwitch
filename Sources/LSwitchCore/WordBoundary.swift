import Foundation

/// Границы последнего слова в строке — чистая логика AX-конвертера,
/// вынесенная для unit-тестов.
public enum WordBoundary {

    /// Символ слова: буква любого алфавита ИЛИ символ с соответствием
    /// в раскладке («;» — это «ж», «'» — «э»): на экране может оказаться
    /// текст, набранный в неправильной раскладке. Хвостовая пунктуация
    /// после извлечения обрезается (см. lastWord).
    public static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || LayoutMap.shared.layout(of: character) != nil
    }

    /// Последнее слово перед позицией курсора.
    ///
    /// Курсор может стоять сразу после разделителя («слово |») — сначала
    /// отступаем за разделители, затем берём непрерывный ряд букв.
    /// - Returns: диапазон слова или `nil`, если слова перед курсором нет.
    public static func lastWord(in text: String, beforeCursor cursor: String.Index) -> Range<String.Index>? {
        var end = cursor
        while end > text.startIndex {
            let previous = text[text.index(before: end)]
            if isWordCharacter(previous) { break }
            end = text.index(before: end)
        }
        var start = end
        while start > text.startIndex {
            let previous = text[text.index(before: start)]
            guard isWordCharacter(previous) else { break }
            start = text.index(before: start)
        }
        // Хвостовая пунктуация («привет,») не входит в слово, внутренняя
        // раскладочная («rf;tncz») — входит.
        while end > start {
            let last = text[text.index(before: end)]
            guard !last.isLetter else { break }
            end = text.index(before: end)
        }
        guard start < end else { return nil }
        return start..<end
    }
}
