import Foundation

/// Словарный классификатор + эвристики F11 (spec auto-classification,
/// design D2).
///
/// Консервативное бинарное правило: конвертируем, только если слово после
/// отображения в другую раскладку есть в словаре другого языка, а само
/// слово отсутствует в словаре текущего. Слова вне словарей и омографы
/// (есть в обоих) не трогаем.
public struct WordClassifier: Sendable {

    public enum Verdict: Equatable, Sendable {
        /// Слово набрано в неправильной раскладке, конвертировать.
        case wrongLayout(converted: String)
        /// Слово корректно для текущей раскладки или недостаточно данных.
        case correct
        /// Эвристика запретила конвертацию (короткое, пароль-подобное,
        /// исключение из персонального словаря).
        case blockedByHeuristics
    }

    private let dictionaries: DictionaryStore
    private let personalDictionary: PersonalDictionary
    private let layoutMap: LayoutMap

    public init(
        dictionaries: DictionaryStore = .shared,
        personalDictionary: PersonalDictionary = PersonalDictionary(),
        layoutMap: LayoutMap = .shared
    ) {
        self.dictionaries = dictionaries
        self.personalDictionary = personalDictionary
        self.layoutMap = layoutMap
    }

    public func verdict(for word: String) -> Verdict {
        guard Self.passesHeuristics(word), !personalDictionary.contains(word) else {
            return .blockedByHeuristics
        }
        let converted = layoutMap.invert(word)
        guard converted != word else { return .correct }
        // Омограф: набранное слово само словарное (на любом языке) — не трогаем.
        if dictionaries.contains(word, language: .russian)
            || dictionaries.contains(word, language: .english) {
            return .correct
        }
        // Конвертированное слово должно быть словарным ровно для одного языка.
        let inRussian = dictionaries.contains(converted, language: .russian)
        let inEnglish = dictionaries.contains(converted, language: .english)
        guard inRussian != inEnglish else { return .correct }
        return .wrongLayout(converted: converted)
    }

    /// Эвристики F11: длина ≥ 3, только буквы или символы с соответствием
    /// в раскладке («;» — это «ж», «'» — «э» и т.д.), без смешанного регистра.
    public static func passesHeuristics(_ word: String) -> Bool {
        guard word.count >= 3 else { return false }
        guard word.allSatisfy({ $0.isLetter || LayoutMap.shared.layout(of: $0) != nil }) else { return false }
        let lowered = word.lowercased()
        let uppered = word.uppercased()
        // Смешанный регистр: слово не нижнее и не верхнее целиком.
        return word == lowered || word == uppered
    }
}
