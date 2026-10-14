import Foundation

public enum ConversionMode: String, Sendable {
    case accessibility
    case clipboard
}

@MainActor
public struct AXConversionEngine: ConversionEngine {
    public init() {}
    public func perform(_ request: ConversionRequest) async -> ConversionResult {
        AXTextConverter().perform(request)
    }
}

@MainActor
public struct ClipboardConversionEngine: ConversionEngine {
    public init() {}
    public func perform(_ request: ConversionRequest) async -> ConversionResult {
        await ClipboardConverter().perform(request)
    }
}

/// Точный оригинал и контекст последней подтверждённой замены.
public struct UndoRecord: Equatable, Sendable {
    public let original: String
    public let converted: String
    public let layoutBefore: Layout
    public let timestamp: Date
    public let trailingText: String
    public let bundleID: String?

    public init(
        original: String, converted: String, layoutBefore: Layout, timestamp: Date,
        trailingText: String = "", bundleID: String? = nil
    ) {
        self.original = original
        self.converted = converted
        self.layoutBefore = layoutBefore
        self.timestamp = timestamp
        self.trailingText = trailingText
        self.bundleID = bundleID
    }
}

/// Используется оркестратором и UI только на главном потоке.
public final class UndoStore {
    public var window: TimeInterval = 3
    private var record: UndoRecord?
    private let now: () -> Date

    public init(now: @escaping () -> Date = { Date() }) { self.now = now }
    public func save(_ record: UndoRecord) { self.record = record }
    public func invalidate() { record = nil }

    public func pendingUndo() -> UndoRecord? {
        guard let record else { return nil }
        guard now().timeIntervalSince(record.timestamp) <= window else {
            self.record = nil
            return nil
        }
        return record
    }
}

/// Один владелец состояния замены и отмены; фоновые шаги не пересекаются.
@MainActor
public final class Converter {
    public typealias ContextCheck = @MainActor @Sendable () -> Bool
    public typealias ContextCapture = @MainActor () -> ContextCheck?

    public enum Outcome: Equatable {
        case converted(original: String, converted: String)
        case undone
        case blockedByRules
        case blockedBySafety
        case unsupportedLayout
        case busy
        case failed

        /// Для диагностики записывается статус, а не пользовательский текст.
        public var label: String {
            switch self {
            case .converted: return "converted"
            case .undone: return "undone"
            case .blockedByRules: return "blockedByRules"
            case .blockedBySafety: return "blockedBySafety"
            case .unsupportedLayout: return "unsupportedLayout"
            case .busy: return "busy"
            case .failed: return "failed"
            }
        }
    }

    private let currentLayout: () -> Layout?
    private let switchLayout: (Layout) -> Void
    private let appRules: AppRules
    private let undoStore: UndoStore
    private let frontmostBundleID: () -> String?
    private let prefersClipboard: (String) -> Bool
    private let makeAXEngine: () -> any ConversionEngine
    private let makeClipboardEngine: () -> any ConversionEngine
    private let captureContext: ContextCapture
    private let onConverted: () -> Void
    private let onLayoutSwitched: (Layout, Layout, UInt64) -> Void
    private let beginInputHold: () -> Bool
    private let endInputHold: () -> Void
    private let isInputHoldValid: () -> Bool
    private var inputHeld = false
    private var revision: UInt64 = 0
    private var undoContext: ContextCheck?
    public private(set) var isBusy = false
    public private(set) var modeCache: [String: ConversionMode] = [:]

    public convenience init(
        layoutManager: LayoutManager,
        appRules: AppRules,
        undoStore: UndoStore,
        frontmostBundleID: @escaping () -> String?,
        prefersClipboard: @escaping (String) -> Bool = { _ in false },
        beginInputHold: @escaping () -> Bool = { true },
        endInputHold: @escaping () -> Void = {},
        isInputHoldValid: @escaping () -> Bool = { true },
        onLayoutSwitched: @escaping (Layout, Layout, UInt64) -> Void = { _, _, _ in },
        onConverted: @escaping () -> Void = {}
    ) {
        self.init(
            currentLayout: { layoutManager.currentLayout() },
            switchLayout: { layoutManager.switchTo($0) },
            appRules: appRules, undoStore: undoStore,
            frontmostBundleID: frontmostBundleID, prefersClipboard: prefersClipboard,
            makeAXEngine: { AXConversionEngine() },
            makeClipboardEngine: { ClipboardConversionEngine() },
            beginInputHold: beginInputHold, endInputHold: endInputHold,
            isInputHoldValid: isInputHoldValid,
            onLayoutSwitched: onLayoutSwitched,
            onConverted: onConverted
        )
    }

    public init(
        currentLayout: @escaping () -> Layout?,
        switchLayout: @escaping (Layout) -> Void,
        appRules: AppRules,
        undoStore: UndoStore,
        frontmostBundleID: @escaping () -> String?,
        prefersClipboard: @escaping (String) -> Bool = { _ in false },
        makeAXEngine: @escaping () -> any ConversionEngine,
        makeClipboardEngine: @escaping () -> any ConversionEngine,
        captureContext: @escaping ContextCapture = {
            guard let target = InputSafety.captureTarget() else { return nil }
            return { target.isCurrent() }
        },
        beginInputHold: @escaping () -> Bool = { true },
        endInputHold: @escaping () -> Void = {},
        isInputHoldValid: @escaping () -> Bool = { true },
        onLayoutSwitched: @escaping (Layout, Layout, UInt64) -> Void = { _, _, _ in },
        onConverted: @escaping () -> Void = {}
    ) {
        self.currentLayout = currentLayout
        self.switchLayout = switchLayout
        self.appRules = appRules
        self.undoStore = undoStore
        self.frontmostBundleID = frontmostBundleID
        self.prefersClipboard = prefersClipboard
        self.makeAXEngine = makeAXEngine
        self.makeClipboardEngine = makeClipboardEngine
        self.captureContext = captureContext
        self.onConverted = onConverted
        self.onLayoutSwitched = onLayoutSwitched
        self.beginInputHold = beginInputHold
        self.endInputHold = endInputHold
        self.isInputHoldValid = isInputHoldValid
    }

    public func notifyOtherKeystroke() {
        revision &+= 1
        undoStore.invalidate()
        undoContext = nil
    }

    @discardableResult
    public func trigger(
        expectedWord: String? = nil,
        trailingText: String = "",
        allowUndo: Bool = true
    ) async -> Outcome {
        guard !isBusy else { return .busy }
        guard let bundleID = frontmostBundleID(), !appRules.isBlocked(bundleID: bundleID) else {
            return .blockedByRules
        }
        guard let check = captureContext(), check() else { return .blockedBySafety }
        guard let layout = currentLayout() else { return .unsupportedLayout }
        isBusy = true
        defer {
            if inputHeld { endInputHold() }
            inputHeld = false
            isBusy = false
        }
        let started = revision
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard beginInputHold() else { return .blockedBySafety }
        inputHeld = true
        let cleanup: ContextCheck = { [weak self] in self?.frontmostBundleID() == bundleID && check() }
        let valid = validityCheck(bundleID: bundleID, revision: started, context: check)
        if allowUndo, let record = undoStore.pendingUndo() {
            guard record.bundleID == bundleID, undoContext?() == true else {
                undoStore.invalidate()
                undoContext = nil
                return .blockedBySafety
            }
            return await undo(
                record, bundleID: bundleID, layout: layout, startedAt: startedAt, checks: (valid, cleanup)
            )
        }
        let request = ConversionRequest(
            expectedWord: expectedWord, trailingText: trailingText,
            sourceLayout: layout, useSelection: allowUndo, beginMutation: mutationGuard(valid),
            canCleanup: cleanup, isValid: valid
        )
        let result = await perform(request, bundleID: bundleID)
        guard case .success(let receipt) = result else { return outcome(for: result) }
        guard valid() else { return .blockedBySafety }
        undoStore.save(UndoRecord(
            original: receipt.original, converted: receipt.converted,
            layoutBefore: layout, timestamp: Date(), trailingText: receipt.trailingText, bundleID: bundleID
        ))
        undoContext = valid
        switchAndRecord(request.targetLayout(for: receipt.original) ?? layout.opposite, from: layout, since: startedAt)
        onConverted()
        return .converted(original: receipt.original, converted: receipt.converted)
    }

    private func undo(
        _ record: UndoRecord, bundleID: String, layout: Layout, startedAt: UInt64,
        checks: (valid: ContextCheck, cleanup: ContextCheck)
    ) async -> Outcome {
        undoStore.invalidate()
        undoContext = nil
        let request = ConversionRequest(
            expectedWord: record.converted, trailingText: record.trailingText,
            replacement: record.original, useSelection: false, beginMutation: mutationGuard(checks.valid),
            canCleanup: checks.cleanup, isValid: checks.valid
        )
        let result = await perform(request, bundleID: bundleID)
        guard case .success(let receipt) = result else { return outcome(for: result) }
        guard checks.valid(), receipt.converted == record.original else { return .failed }
        switchAndRecord(record.layoutBefore, from: layout, since: startedAt)
        return .undone
    }

    private func switchAndRecord(_ target: Layout, from source: Layout, since startedAt: UInt64) {
        switchLayout(target)
        guard source != target, currentLayout() == target else { return }
        onLayoutSwitched(source, target, startedAt)
    }

    private func mutationGuard(_ valid: @escaping ContextCheck) -> ContextCheck {
        { [weak self] in
            guard let self, valid() else { return false }
            if self.inputHeld { return true }
            self.inputHeld = self.beginInputHold()
            return self.inputHeld
        }
    }

    private func validityCheck(
        bundleID: String, revision started: UInt64, context: @escaping ContextCheck
    ) -> ContextCheck {
        { [weak self] in
            guard let self, self.revision == started, self.frontmostBundleID() == bundleID, context() else {
                return false
            }
            return !self.inputHeld || self.isInputHoldValid()
        }
    }

    private func perform(_ request: ConversionRequest, bundleID: String) async -> ConversionResult {
        guard request.isValid() else { return .blocked }
        if modeCache[bundleID] == .clipboard || prefersClipboard(bundleID) {
            return await makeClipboardEngine().perform(request)
        }
        let result = await makeAXEngine().perform(request)
        switch result {
        case .success:
            modeCache[bundleID] = .accessibility
            return result
        case .unavailable:
            guard request.isValid() else { return .blocked }
            let fallback = await makeClipboardEngine().perform(request)
            if case .success = fallback { modeCache[bundleID] = .clipboard }
            return fallback
        case .blocked, .failed:
            return result
        }
    }

    private func outcome(for result: ConversionResult) -> Outcome {
        if case .blocked = result { return .blockedBySafety }
        return .failed
    }
}
