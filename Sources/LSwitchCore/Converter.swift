import Foundation

/// Один владелец состояния замены и отмены; фоновые шаги не пересекаются.
@MainActor
public final class Converter {
    public typealias ContextCheck = @MainActor @Sendable () -> Bool
    public typealias ContextCapture = @MainActor () -> ContextCheck?
    /// nil допустим только до захвата ввода. Начатая очередь обязана вернуться с удерживающей её Session.
    public typealias RecoverySessionFactory = @MainActor (ConversionRecoveryContext) async -> ConversionRecoverySession?

    let currentLayout: () -> Layout?
    let switchLayout: (Layout) -> Bool
    private let appRules: AppRules
    let undoStore: UndoStore
    private let frontmostBundleID: () -> String?
    let prefersClipboard: (String) -> Bool
    let makeAXEngine: () -> any ConversionEngine
    let makeClipboardEngine: () -> any ConversionEngine
    let makeUnicodeEngine: ((String) -> (any ConversionEngine)?)?
    let captureContext: ContextCapture?
    let onConverted: () -> Void
    private let onLayoutSwitched: (Layout, Layout, UInt64) -> Void
    private let beginInputHold: () -> Bool
    private let endInputHold: () -> Void
    private let isInputHoldValid: () -> Bool
    private let drainPendingInput: () async -> Void
    private var inputHeld = false
    private var revision: UInt64 = 0
    var undoContext: ContextCheck?
    var undoDocumentTarget: ConversionReceipt.TargetCheck?
    var diagnosticAttempts: [String: Int] = [:]
    private let recoverySessionFactory: RecoverySessionFactory?
    private let recoveryOwner: ConversionRecoveryOwner?
    private var retainedRecoverySession: ConversionRecoverySession?

    public var hasPendingRecovery: Bool {
        recoveryOwner?.hasPendingRecovery == true || retainedRecoverySession?.requiresRecovery == true
    }

    private struct OperationContext {
        let bundleID: String
        let layout: Layout
        let startedAt: UInt64
        let valid: ContextCheck
        let cleanup: ContextCheck
        let diagnostics: ConversionDiagnostics
    }
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
        drainPendingInput: @escaping () async -> Void = {},
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
            isInputHoldValid: isInputHoldValid, drainPendingInput: drainPendingInput,
            onLayoutSwitched: onLayoutSwitched,
            onConverted: onConverted
        )
    }

    public init(
        currentLayout: @escaping () -> Layout?,
        switchLayout: @escaping (Layout) -> Bool,
        appRules: AppRules,
        undoStore: UndoStore,
        frontmostBundleID: @escaping () -> String?,
        prefersClipboard: @escaping (String) -> Bool = { _ in false },
        makeAXEngine: @escaping () -> any ConversionEngine,
        makeClipboardEngine: @escaping () -> any ConversionEngine,
        makeUnicodeEngine: ((String) -> (any ConversionEngine)?)? = nil,
        recoverySessionFactory: RecoverySessionFactory? = nil,
        recoveryOwner: ConversionRecoveryOwner? = nil,
        captureContext: ContextCapture? = nil,
        beginInputHold: @escaping () -> Bool = { true },
        endInputHold: @escaping () -> Void = {},
        isInputHoldValid: @escaping () -> Bool = { true },
        drainPendingInput: @escaping () async -> Void = {},
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
        self.makeUnicodeEngine = makeUnicodeEngine
        self.recoverySessionFactory = recoverySessionFactory
        self.recoveryOwner = recoveryOwner
        self.captureContext = captureContext
        self.onConverted = onConverted
        self.onLayoutSwitched = onLayoutSwitched
        self.beginInputHold = beginInputHold
        self.endInputHold = endInputHold
        self.isInputHoldValid = isInputHoldValid
        self.drainPendingInput = drainPendingInput
    }

    public func notifyOtherKeystroke() {
        revision &+= 1
        undoStore.invalidate()
        undoContext = nil
        undoDocumentTarget = nil
    }

    @discardableResult
    public func trigger(
        expectedWord: String? = nil,
        trailingText: String = "",
        allowUndo: Bool = true,
        triggerTimestamp: UInt64? = nil,
        diagnostics: ConversionDiagnostics? = nil
    ) async -> Outcome {
        let bundleID = frontmostBundleID()
        let trace = diagnostics ?? makeDiagnostics(
            bundleID: bundleID, triggerTimestamp: triggerTimestamp, automatic: !allowUndo
        )
        let outcome = await trigger(
            expectedWord: expectedWord, trailingText: trailingText,
            allowUndo: allowUndo, bundleID: bundleID, diagnostics: trace
        )
        trace.finish(outcome)
        return outcome
    }
}
extension Converter {
    private func trigger(
        expectedWord: String?, trailingText: String, allowUndo: Bool,
        bundleID: String?, diagnostics: ConversionDiagnostics
    ) async -> Outcome {
        guard !isBusy else {
            diagnostics.reject(.busy)
            return .busy
        }
        guard !hasPendingRecovery else { return .recoveryRequired }
        guard recoveryOwner?.isOccupied != true else { return .busy }
        guard let bundleID, !appRules.isBlocked(bundleID: bundleID) else {
            diagnostics.reject(.rules)
            return .blockedByRules
        }
        guard let check = captureCheck(diagnostics: diagnostics), check() else {
            diagnostics.reject(.contextUnavailable)
            return .blockedBySafety
        }
        diagnostics.mark(.contextCaptured)
        guard let layout = currentLayout() else {
            diagnostics.reject(.unsupportedLayout)
            return .unsupportedLayout
        }
        if let factory = recoverySessionFactory {
            let scope = ConverterTrackedScope(
                bundleID: bundleID, layout: layout, check: check, diagnostics: diagnostics)
            let input = ConverterTrackedInput(
                expectedWord: expectedWord, trailingText: trailingText, allowUndo: allowUndo)
            return await runTracked(factory: factory, scope: scope, input: input)
        }
        isBusy = true
        defer {
            if inputHeld { endInputHold() }
            inputHeld = false
            isBusy = false
        }
        let started = revision
        let startedAt = DispatchTime.now().uptimeNanoseconds
        guard beginInputHold() else {
            diagnostics.reject(.holdUnavailable)
            return .blockedBySafety
        }
        inputHeld = true
        diagnostics.mark(.holdAcquired)
        let cleanup: ContextCheck = { [weak self] in self?.frontmostBundleID() == bundleID && check() }
        let valid = validityCheck(bundleID: bundleID, revision: started, context: check, diagnostics: diagnostics)
        await drainPendingInput()
        diagnostics.mark(.pendingInputDrained)
        guard valid() else { return .blockedBySafety }
        let operation = OperationContext(
            bundleID: bundleID, layout: layout, startedAt: startedAt,
            valid: valid, cleanup: cleanup, diagnostics: diagnostics
        )
        return await convert(expectedWord: expectedWord, trailingText: trailingText, allowUndo: allowUndo,
                             operation: operation)
    }

    private func runTracked(
        factory: RecoverySessionFactory, scope: ConverterTrackedScope, input: ConverterTrackedInput
    ) async -> Outcome {
        let diagnostics = scope.diagnostics
        isBusy = true
        defer { isBusy = false }
        guard let owner = recoveryOwner, let admission = owner.reserve() else {
            diagnostics.reject(.holdUnavailable)
            return .blockedBySafety
        }
        defer { owner.finishInvocation(admission) }
        let started = revision
        let context = ConversionRecoveryContext(
            bundleID: scope.bundleID, sourceLayout: scope.layout, generation: started,
            startedAt: DispatchTime.now().uptimeNanoseconds, admission: admission,
            isCurrent: { [weak self] in
                self?.revision == started && self?.frontmostBundleID() == scope.bundleID && scope.check()
            }, canCleanup: { [weak self] in self?.frontmostBundleID() == scope.bundleID && scope.check() }
        )
        guard let session = await factory(context) else {
            if let pending = owner.session(for: admission) {
                pending.retainIfUnfinished()
                return .recoveryRequired
            }
            diagnostics.reject(.holdUnavailable)
            return .blockedBySafety
        }
        guard let registered = owner.session(for: admission) else {
            diagnostics.reject(.holdUnavailable)
            return .blockedBySafety
        }
        guard registered === session else { registered.retainIfUnfinished(); return .recoveryRequired }
        retainedRecoverySession = session
        defer {
            session.retainIfUnfinished()
            if !session.requiresRecovery { retainedRecoverySession = nil }
        }
        guard session.matches(context), session.isValid else { return .recoveryRequired }
        return await trackedConversion(input: input, context: context, session: session, diagnostics: diagnostics)
    }

    func cacheTrackedMode(_ mechanism: ConversionDiagnostics.Mechanism, bundleID: String) {
        if mechanism == .accessibility { modeCache[bundleID] = .accessibility }
        if mechanism == .clipboard { modeCache[bundleID] = .clipboard }
    }

    private func convert(
        expectedWord: String?, trailingText: String, allowUndo: Bool, operation: OperationContext
    ) async -> Outcome {
        if allowUndo, let record = undoStore.pendingUndo() {
            guard record.bundleID == operation.bundleID, undoContext?() == true else {
                undoStore.invalidate()
                undoContext = nil
                undoDocumentTarget = nil
                operation.diagnostics.reject(.contextChanged)
                return .blockedBySafety
            }
            return await undo(record, operation: operation)
        }
        let request = ConversionRequest(
            expectedWord: expectedWord, trailingText: trailingText,
            sourceLayout: operation.layout, useSelection: allowUndo, diagnostics: operation.diagnostics,
            beginMutation: mutationGuard(operation.valid),
            canCleanup: operation.cleanup, isValid: operation.valid
        )
        let result = await perform(request, bundleID: operation.bundleID)
        guard case .success(let receipt) = result else {
            return outcome(for: result, diagnostics: operation.diagnostics)
        }
        operation.diagnostics.mark(.textConfirmed)
        guard operation.valid(), receipt.targetIsCurrent?() != false else { return .blockedBySafety }
        undoStore.save(UndoRecord(
            original: receipt.original, converted: receipt.converted,
            layoutBefore: operation.layout, timestamp: Date(),
            trailingText: receipt.trailingText, bundleID: operation.bundleID
        ))
        undoDocumentTarget = receipt.targetIsCurrent
        undoContext = { operation.valid() && receipt.targetIsCurrent?() != false }
        let target = request.targetLayout(for: receipt.original) ?? operation.layout.opposite
        operation.diagnostics.recordLayoutDecision(source: operation.layout, target: target, receipt: receipt)
        return finishConversion(receipt, target: target, source: operation.layout,
                                since: operation.startedAt, diagnostics: operation.diagnostics)
    }

    private func finishConversion(
        _ receipt: ConversionReceipt, target: Layout, source: Layout, since startedAt: UInt64,
        diagnostics: ConversionDiagnostics
    ) -> Outcome {
        guard switchAndRecord(target, from: source, since: startedAt, diagnostics: diagnostics) else {
            return .partiallyConverted(original: receipt.original, converted: receipt.converted, targetLayout: target)
        }
        onConverted()
        return .converted(original: receipt.original, converted: receipt.converted)
    }

    private func undo(_ record: UndoRecord, operation: OperationContext) async -> Outcome {
        let previousTarget = undoDocumentTarget
        undoStore.invalidate()
        undoContext = nil
        undoDocumentTarget = nil
        let request = ConversionRequest(
            expectedWord: record.converted, trailingText: record.trailingText,
            replacement: record.original, useSelection: false, diagnostics: operation.diagnostics,
            beginMutation: mutationGuard(operation.valid),
            canCleanup: operation.cleanup, isValid: operation.valid
        ).checkingTarget(previousTarget)
        let result = await perform(request, bundleID: operation.bundleID)
        guard case .success(let receipt) = result else {
            return outcome(for: result, diagnostics: operation.diagnostics)
        }
        operation.diagnostics.mark(.textConfirmed)
        guard request.isValid(), receipt.converted == record.original else { return .failed }
        operation.diagnostics.recordLayoutDecision(
            source: operation.layout, target: record.layoutBefore, receipt: receipt
        )
        guard switchAndRecord(record.layoutBefore, from: operation.layout,
                              since: operation.startedAt, diagnostics: operation.diagnostics) else {
            return .partiallyUndone(targetLayout: record.layoutBefore)
        }
        return .undone
    }

    /// Полный успех требует подтверждения адаптера и текущего источника.
    /// Уже подходящая раскладка не требует новой команды и не создаёт окно коррекции Unicode.
    private func switchAndRecord(
        _ target: Layout, from source: Layout, since startedAt: UInt64, diagnostics: ConversionDiagnostics
    ) -> Bool {
        if source == target {
            let observed = currentLayout()
            diagnostics.recordLayoutObservation(stage: .alreadyTarget, accepted: nil, observed: observed)
            if observed == target {
                diagnostics.mark(.layoutConfirmed)
                return true
            }
        }
        let accepted = switchLayout(target)
        diagnostics.recordLayoutObservation(stage: .adapter, accepted: accepted, observed: nil)
        guard accepted else { return diagnostics.reject(.layoutNotConfirmed) }
        let observed = currentLayout()
        diagnostics.recordLayoutObservation(stage: .readback, accepted: accepted, observed: observed)
        guard observed == target else { return diagnostics.reject(.layoutNotConfirmed) }
        diagnostics.mark(.layoutConfirmed)
        if source != target { onLayoutSwitched(source, target, startedAt) }
        return true
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
        bundleID: String, revision started: UInt64, context: @escaping ContextCheck,
        diagnostics: ConversionDiagnostics
    ) -> ContextCheck {
        { [weak self] in
            guard let self else { return diagnostics.reject(.contextUnavailable) }
            guard self.revision == started else { return diagnostics.reject(.generationChanged) }
            guard self.frontmostBundleID() == bundleID else { return diagnostics.reject(.applicationChanged) }
            guard context() else { return diagnostics.reject(.contextChanged) }
            guard !self.inputHeld || self.isInputHoldValid() else { return diagnostics.reject(.holdExpired) }
            return true
        }
    }

    private func perform(_ request: ConversionRequest, bundleID: String) async -> ConversionResult {
        guard request.isValid() else { return .blocked }
        if let engine = makeUnicodeEngine?(bundleID) {
            request.diagnostics?.mark(.engineStarted, mechanism: .unicode)
            return await engine.perform(request)
        }
        if modeCache[bundleID] == .clipboard || prefersClipboard(bundleID) {
            request.diagnostics?.mark(.engineStarted, mechanism: .clipboard)
            return await makeClipboardEngine().perform(request)
        }
        request.diagnostics?.mark(.engineStarted, mechanism: .accessibility)
        let result = await makeAXEngine().perform(request)
        switch result {
        case .success:
            modeCache[bundleID] = .accessibility
            return result
        case .unavailable:
            guard request.isValid() else { return .blocked }
            request.diagnostics?.mark(.engineStarted, mechanism: .clipboard)
            let fallback = await makeClipboardEngine().perform(request)
            if case .success = fallback { modeCache[bundleID] = .clipboard }
            return fallback
        case .blocked, .failed:
            return result
        }
    }

}
