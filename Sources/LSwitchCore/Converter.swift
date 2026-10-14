import Foundation

/// Режим конвертации (design D4): AX-first, clipboard — fallback.
public enum ConversionMode: String, Sendable {
    case accessibility
    case clipboard
}

/// Единый интерфейс движков конвертации для оркестратора (и моков в тестах).
public protocol ConversionEngine: Sendable {
    /// Выполняет конвертацию, возвращает (исходный текст, результат) или nil.
    func perform() async -> (original: String, converted: String)?
}

public struct AXConversionEngine: ConversionEngine {
    public init() {}
    public func perform() async -> (original: String, converted: String)? {
        switch AXTextConverter().convert() {
        case .success(let outcome):
            return (outcome.original, outcome.converted)
        case .failure:
            return nil
        }
    }
}

public struct ClipboardConversionEngine: ConversionEngine {
    public init() {}
    public func perform() async -> (original: String, converted: String)? {
        switch await ClipboardConverter().convertSelection() {
        case .success(let original, let converted):
            return (original, converted)
        case .copyFailed:
            return nil
        }
    }
}

/// Запись о последней конвертации для отката (design D2).
public struct UndoRecord: Equatable, Sendable {
    public let original: String
    public let converted: String
    public let layoutBefore: Layout
    public let timestamp: Date
}

/// Одноэлементное хранилище отката: валидно в пределах окна (по умолчанию
/// 3 с) и сбрасывается любым другим нажатием клавиши.
public final class UndoStore {

    public var window: TimeInterval = 3

    private var record: UndoRecord?
    private let now: () -> Date

    public init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    public func save(_ record: UndoRecord) {
        self.record = record
    }

    /// Запись для отката, если окно не истекло; просроченная запись удаляется.
    public func pendingUndo() -> UndoRecord? {
        guard let record else { return nil }
        guard now().timeIntervalSince(record.timestamp) <= window else {
            self.record = nil
            return nil
        }
        return record
    }

    public func invalidate() {
        record = nil
    }
}

/// Оркестратор ручной конвертации: AX → clipboard-fallback, per-app кэш
/// режима, откат, переключение раскладки следом (design D2, D4).
public final class Converter {

    public enum Outcome: Equatable {
        case converted(original: String, converted: String)
        case undone
        /// Активное приложение в списке исключений.
        case blockedByRules
        /// Раскладка вне пары ru/en — конвертировать нечего.
        case unsupportedLayout
        /// Оба движка завершились ошибкой.
        case failed
    }

    private let currentLayout: @Sendable () -> Layout?
    private let switchLayout: @Sendable (Layout) -> Void
    private let appRules: AppRules
    private let undoStore: UndoStore
    private let frontmostBundleID: @Sendable () -> String?
    private let makeAXEngine: @Sendable () -> any ConversionEngine
    private let makeClipboardEngine: @Sendable () -> any ConversionEngine
    /// Вызывается после успешной конвертации (звук в UI-слое).
    private let onConverted: @Sendable () -> Void

    /// Кэш «приложение → рабочий режим» на время сессии (design D4).
    public private(set) var modeCache: [String: ConversionMode] = [:]

    public convenience init(
        layoutManager: LayoutManager,
        appRules: AppRules,
        undoStore: UndoStore,
        frontmostBundleID: @escaping @Sendable () -> String?,
        makeAXEngine: @escaping @Sendable () -> any ConversionEngine = { AXConversionEngine() },
        makeClipboardEngine: @escaping @Sendable () -> any ConversionEngine = { ClipboardConversionEngine() },
        onConverted: @escaping @Sendable () -> Void = {}
    ) {
        self.init(
            currentLayout: { layoutManager.currentLayout() },
            switchLayout: { layoutManager.switchTo($0) },
            appRules: appRules,
            undoStore: undoStore,
            frontmostBundleID: frontmostBundleID,
            makeAXEngine: makeAXEngine,
            makeClipboardEngine: makeClipboardEngine,
            onConverted: onConverted
        )
    }

    public init(
        currentLayout: @escaping @Sendable () -> Layout?,
        switchLayout: @escaping @Sendable (Layout) -> Void,
        appRules: AppRules,
        undoStore: UndoStore,
        frontmostBundleID: @escaping @Sendable () -> String?,
        makeAXEngine: @escaping @Sendable () -> any ConversionEngine,
        makeClipboardEngine: @escaping @Sendable () -> any ConversionEngine,
        onConverted: @escaping @Sendable () -> Void = {}
    ) {
        self.currentLayout = currentLayout
        self.switchLayout = switchLayout
        self.appRules = appRules
        self.undoStore = undoStore
        self.frontmostBundleID = frontmostBundleID
        self.makeAXEngine = makeAXEngine
        self.makeClipboardEngine = makeClipboardEngine
        self.onConverted = onConverted
    }

    /// Любое нажатие, не являющееся хоткеем конвертации, сбрасывает откат.
    public func notifyOtherKeystroke() {
        undoStore.invalidate()
    }

    /// Точка входа по хоткею: откат в окне, иначе новая конвертация.
    /// Автоматика вызывает с allowUndo: false — разделитель не должен
    /// откатывать предыдущую конвертацию.
    @discardableResult
    public func trigger(allowUndo: Bool = true) async -> Outcome {
        if allowUndo, undoStore.pendingUndo() != nil {
            return await undo()
        }
        return await convert()
    }

    private func convert() async -> Outcome {
        guard let bundleID = frontmostBundleID(), !appRules.isBlocked(bundleID: bundleID) else {
            return .blockedByRules
        }
        guard let layoutBefore = currentLayout() else {
            return .unsupportedLayout
        }
        guard let (original, converted) = await performConversion(bundleID: bundleID) else {
            return .failed
        }
        undoStore.save(UndoRecord(
            original: original,
            converted: converted,
            layoutBefore: layoutBefore,
            timestamp: Date()
        ))
        switchLayout(layoutBefore.opposite)
        onConverted()
        return .converted(original: original, converted: converted)
    }

    private func undo() async -> Outcome {
        guard let record = undoStore.pendingUndo() else { return await convert() }
        undoStore.invalidate()
        // Откат — обратная конвертация (invert симметричен, design D2).
        guard await performConversion(bundleID: frontmostBundleID() ?? "") != nil else {
            return .failed
        }
        switchLayout(record.layoutBefore)
        return .undone
    }

    /// Возвращает пару (исходник, результат): сначала кэшированный/AX-режим,
    /// при неудаче — clipboard, успешный режим запоминается.
    private func performConversion(bundleID: String) async -> (String, String)? {
        let cached = modeCache[bundleID]
        if cached == .clipboard {
            return await makeClipboardEngine().perform()
        }
        if let result = await makeAXEngine().perform() {
            modeCache[bundleID] = .accessibility
            return result
        }
        if let result = await makeClipboardEngine().perform() {
            modeCache[bundleID] = .clipboard
            return result
        }
        return nil
    }
}
