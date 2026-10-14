import Foundation

/// Одно событие клавиатуры в буфере.
public struct Keystroke: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Печатный символ, входящий в слово.
        case character(Character)
        /// Разделитель слов (пробел, знак препинания без соответствия в раскладке, Enter).
        case delimiter(Character)
        /// Управляющая клавиша: курсорные, Delete, Escape, Tab — сбрасывает контекст слова.
        case control
    }

    public let kind: Kind
    public let timestamp: Date
    /// Событие сгенерировано самим LSwitch (симуляция) и должно игнорироваться логикой.
    public let isSynthetic: Bool

    public init(kind: Kind, timestamp: Date = Date(), isSynthetic: Bool = false) {
        self.kind = kind
        self.timestamp = timestamp
        self.isSynthetic = isSynthetic
    }
}

/// Потокобезопасный кольцевой буфер последних нажатий клавиш.
///
/// Хранит ограниченный хвост ввода (по умолчанию 256 символов) только в памяти —
/// по требованию приватности ничего не пишется на диск.
public final class KeystrokeBuffer: @unchecked Sendable {

    public static let defaultCapacity = 256

    private let capacity: Int
    private var storage: [Keystroke] = []
    private let lock = NSLock()

    public init(capacity: Int = KeystrokeBuffer.defaultCapacity) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage.reserveCapacity(capacity)
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    public func append(_ keystroke: Keystroke) {
        guard !keystroke.isSynthetic else { return }
        lock.lock()
        defer { lock.unlock() }
        if case .control = keystroke.kind {
            storage.removeAll(keepingCapacity: true)
            return
        }
        storage.append(keystroke)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    /// Последнее введённое слово — символы от конца буфера
    /// до ближайшего разделителя или начала буфера.
    public func lastWord() -> String {
        lock.lock()
        defer { lock.unlock() }
        var word: [Character] = []
        for keystroke in storage.reversed() {
            guard case .character(let letter) = keystroke.kind else { break }
            word.append(letter)
        }
        return String(word.reversed())
    }

    /// Удаляет последнее слово из буфера (вызывается после успешной конвертации,
    /// чтобы дальше работать с уже конвертированным текстом).
    public func removeLastWord() {
        lock.lock()
        defer { lock.unlock() }
        while let last = storage.last, case .character = last.kind {
            storage.removeLast()
        }
    }

    /// Последнее слово для автопереключения: игнорирует завершающие
    /// разделители и обрезает хвостовую пунктуацию («ghbdtn,» → «ghbdtn»),
    /// но сохраняет раскладочные символы внутри слова («rf;tncz»).
    public func lastWordForAutoSwitch() -> String {
        var word = lastWordBeforeDelimiter()
        while let last = word.last, !last.isLetter {
            word.removeLast()
        }
        return word
    }

    /// Удаляет последний разделитель (если он есть) — после автоконвертации
    /// разделитель вводится заново уже в новой раскладке.
    public func removeLastDelimiter() {
        lock.lock()
        defer { lock.unlock() }
        if let last = storage.last, case .delimiter = last.kind {
            storage.removeLast()
        }
    }

    /// Последнее слово, игнорируя завершающие разделители: для проверки
    /// автопереключения в момент, когда разделитель только что набран
    /// и уже лежит в буфере.
    public func lastWordBeforeDelimiter() -> String {
        lock.lock()
        defer { lock.unlock() }
        var word: [Character] = []
        var skippingDelimiters = true
        for keystroke in storage.reversed() {
            switch keystroke.kind {
            case .character(let letter):
                skippingDelimiters = false
                word.append(letter)
            case .delimiter:
                if !skippingDelimiters { return String(word.reversed()) }
            case .control:
                return String(word.reversed())
            }
        }
        return String(word.reversed())
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll(keepingCapacity: true)
    }
}
