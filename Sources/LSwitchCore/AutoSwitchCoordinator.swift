import Foundation

/// Координатор автопереключения (design D3, D4): решает, конвертировать
/// ли последнее слово после разделителя, и реализует обучение на отменах.
/// Вызывается из очереди обработки перехвата и из Task конвертации —
/// внутреннее состояние защищено замком.
public final class AutoSwitchCoordinator: @unchecked Sendable {

    /// Порог обучения: столько отмен автоконвертации слова отправляют его
    /// в персональный словарь (TZ.md F11, по умолчанию 2).
    public static let learningThreshold = 2

    private let classifier: WordClassifier
    private let personalDictionary: PersonalDictionary
    private let lock = NSLock()

    /// Счётчик отмен по нормализованному слову (нижний регистр), в памяти.
    private var undoCounts: [String: Int] = [:]

    /// Слово последней автоконвертации — кандидат на обучение при откате.
    public private(set) var lastAutoConvertedWord: String?

    public init(
        classifier: WordClassifier = WordClassifier(),
        personalDictionary: PersonalDictionary = PersonalDictionary()
    ) {
        self.classifier = classifier
        self.personalDictionary = personalDictionary
    }

    /// Вызывается на разделителе. Возвращает конвертированный вариант,
    /// если слово нужно автоконвертировать.
    public func evaluate(word: String) -> String? {
        guard case .wrongLayout(let converted) = classifier.verdict(for: word) else { return nil }
        lock.lock()
        lastAutoConvertedWord = word
        lock.unlock()
        return converted
    }

    /// Откат автоконвертации: учит словарь. Откаты ручной конвертации
    /// сюда не приходят (design D4) — `lastAutoConvertedWord` тогда nil.
    public func registerUndo() {
        lock.lock()
        defer { lock.unlock() }
        guard let word = lastAutoConvertedWord else { return }
        let key = word.lowercased()
        let count = (undoCounts[key] ?? 0) + 1
        if count >= Self.learningThreshold {
            personalDictionary.add(key)
            undoCounts[key] = nil
        } else {
            undoCounts[key] = count
        }
        lastAutoConvertedWord = nil
    }

    /// Конвертация состоялась и не была отменена — кандидат сбрасывается.
    public func clearPendingUndoCandidate() {
        lock.lock()
        lastAutoConvertedWord = nil
        lock.unlock()
    }
}
