import AppKit
import ApplicationServices
import Foundation

/// Системная граница clipboard-операции. Тесты подменяют фокус, клавиши, время и pasteboard.
@MainActor
struct ClipboardEnvironment {
    typealias TextState = (text: String, selection: NSRange)
    enum SelectionMethod { case accessibility, keyboard }

    struct Context {
        let identity = UUID()
        var isValid: () -> Bool
        var selectedText: () -> String?
        var readState: () -> TextState? = { nil }
        var setSelection: (NSRange) -> Bool = { _ in false }
        var prepareSelection: (NSRange) -> AXPreparedWrite? = { _ in nil }
        var safetyFailure: (() -> ConversionDiagnostics.Rejection?)?
        var automaticContext: () -> AutomaticTextContext = { .prose }
        var documentIdentity: @MainActor @Sendable () -> String? = { nil }
        var selectionMethod: SelectionMethod = .accessibility
    }

    var captureContext: () -> Context?
    var prepare: (@escaping @MainActor () -> Bool) -> Void = { _ in }
    var capture: () async -> PasteboardCaptureResult
    var restore: (PasteboardSnapshot) -> Void
    var changeCount: () -> Int
    var string: () -> String?
    var write: (String) -> (succeeded: Bool, changeCount: Int)
    var send: (ClipboardCommand, @escaping @MainActor () -> Bool) async -> Bool
    var commitPaste: (
        @escaping @MainActor () async -> Bool, @escaping @MainActor () -> Bool, @escaping @MainActor () -> Bool
    ) async -> MenuCommand.Outcome = { _, _, _ in .unavailable }
    var sleep: (TimeInterval) async -> Void
    var settlementPause: (() async -> Void)?
    var waitForPendingInput: () async -> Void = {}
    var bindDiagnostics: (ConversionDiagnostics?) -> Void = { _ in }
    var receiverContract: ClipboardReceiverContract?
    var writeTracked: ((String, @escaping @MainActor () -> Bool) -> (succeeded: Bool, changeCount: Int)?)?
    var sendTracked: (
        (ClipboardCommand, @escaping @MainActor () -> Bool, ClipboardDispatchHooks) async -> Bool
    )?
    var commitPasteTracked: (
        (@escaping @MainActor () async -> Bool, @escaping @MainActor () -> Bool,
         @escaping @MainActor () -> Bool, ClipboardDispatchHooks) async -> MenuCommand.Outcome
    )?

    static func live(
        pasteboard: NSPasteboard, keyboardOnly: Bool = false,
        applicationPolicy: ClipboardApplicationPolicy? = nil
    ) -> ClipboardEnvironment {
        let binding = ClipboardDiagnosticsBinding()
        let transport = makeTransport(forceKeyboard: keyboardOnly, diagnostics: binding)
        let policy = applicationPolicy ?? ClipboardApplicationPolicy()
        return ClipboardEnvironment(
            captureContext: { makeContext(applicationPolicy: policy) },
            prepare: { transport.prepare(isValid: $0) },
            capture: {
                await PasteboardCaptureWorker.shared.capture(named: pasteboard.name.rawValue,
                                                             diagnostics: binding.diagnostics)
            },
            restore: { PasteboardService.restore($0, to: pasteboard) },
            changeCount: { pasteboard.changeCount },
            string: { pasteboard.string(forType: .string) },
            write: {
                let ownedCount = pasteboard.clearContents()
                return (pasteboard.setString($0, forType: .string), ownedCount)
            },
            send: { await transport.send($0, isValid: $1) },
            commitPaste: { select, check, isValid in
                await transport.commitPaste(select: select, check: check, isValid: isValid)
            },
            sleep: { delay in
                guard delay > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            },
            settlementPause: { await SelectionSettlement.pause() },
            waitForPendingInput: { await Self.drainMainQueue() },
            bindDiagnostics: { binding.diagnostics = $0 },
            writeTracked: { text, canWrite in
                guard canWrite() else { return nil }
                let count = pasteboard.clearContents()
                return (pasteboard.setString(text, forType: .string), count)
            },
            sendTracked: { await transport.send($0, isValid: $1, hooks: $2) },
            commitPasteTracked: { select, check, valid, hooks in
                await transport.commitPaste(select: select, check: check, isValid: valid, hooks: hooks)
            }
        )
    }

    static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func makeTransport(
        forceKeyboard: Bool, diagnostics: ClipboardDiagnosticsBinding
    ) -> ClipboardCommandTransport {
        ClipboardCommandTransport(
            forceKeyboard: forceKeyboard,
            currentTarget: {
                guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
                return .init(processID: application.processIdentifier, bundleID: application.bundleIdentifier)
            },
            prepareMenu: { MenuCommand.prepare(targetPID: $0, isValid: $1) },
            invokeMenu: { MenuCommand.invoke($0, targetPID: $1, isValid: $2) },
            commitMenu: { targetPID, select, check, isValid in
                await MenuCommand.pasteAfterSelection(
                    targetPID: targetPID, select: select, afterSelectionCheck: check, isValid: isValid
                )
            },
            sendKeyboard: { command, targetPID, isValid, beforeKeyDown in
                await KeyboardEmitter.send(
                    command, targetPID: targetPID, isValid: isValid, beforeKeyDown: beforeKeyDown,
                    observer: { diagnostics.mark($0) }
                )
            },
            invokeMenuTracked: { MenuCommand.invoke($0, targetPID: $1, isValid: $2, hooks: $3) },
            commitMenuTracked: { targetPID, select, check, valid, hooks in
                await MenuCommand.pasteAfterSelection(
                    targetPID: targetPID, select: select, afterSelectionCheck: check, isValid: valid, hooks: hooks
                )
            },
            sendKeyboardTracked: { command, targetPID, valid, beforeKeyDown, hooks in
                await KeyboardEmitter.send(
                    command, targetPID: targetPID, isValid: valid, beforeKeyDown: beforeKeyDown,
                    observer: { diagnostics.mark($0) }, hooks: hooks
                )
            }
        )
    }

    private static func makeContext(applicationPolicy: ClipboardApplicationPolicy) -> Context? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return applicationPolicy.capture(bundleID: application.bundleIdentifier) {
            guard let target = InputSafety.captureTarget(),
                  target.capturedApplicationPID == application.processIdentifier else { return nil }
            return makeContext(target: target, bundleID: application.bundleIdentifier)
        }
    }

    private static func makeContext(target: InputTarget, bundleID: String?) -> Context {
        let keyboardSelection = AppProfiles.prefersKeyboardSelection(bundleID: bundleID)
        return Context(isValid: { target.isCurrent() }, selectedText: {
            guard target.isCurrent() else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                target.element, kAXSelectedTextAttribute as CFString, &value
            ) == .success else { return nil }
            return value as? String
        }, readState: {
            guard target.isCurrent() else { return nil }
            return readState(of: target.element)
        }, setSelection: { range in
            let access = SystemAXTextAccess()
            guard target.isCurrent(), access.canSetSelection(in: target.element) else { return false }
            return access.setSelection(range, in: target.element) && target.isCurrent()
        }, prepareSelection: { range in
            let access = SystemAXTextAccess()
            guard target.isCurrent(), access.canSetSelection(in: target.element) else { return nil }
            return access.prepareSelection(range, in: target.element)
        }, safetyFailure: { target.invalidationReason }, automaticContext: {
            guard target.isCurrent() else { return .unknown }
            let context = SystemAutomaticTextContext.read(in: target.element)
            return target.isCurrent() ? context : .unknown
        }, documentIdentity: {
            guard target.isCurrent() else { return nil }
            let identity = SystemAutomaticTextContext.documentIdentity(in: target.element)
            return target.isCurrent() ? identity : nil
        }, selectionMethod: keyboardSelection ? .keyboard : .accessibility)
    }

    private static func readState(of element: AXUIElement) -> TextState? {
        var value: CFTypeRef?
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String,
              AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &selection
              ) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(selection as! AXValue, .cfRange, &range) else { return nil }
        let result = NSRange(location: range.location, length: range.length)
        guard Range(result, in: text) != nil else { return nil }
        return (text, result)
    }
}

/// Один converter выполняет только одну транзакцию; binding снимается в defer run().
@MainActor
private final class ClipboardDiagnosticsBinding {
    weak var diagnostics: ConversionDiagnostics?

    func mark(_ phase: KeyboardEmitter.Phase) {
        let mapped: ConversionDiagnostics.Phase
        switch phase {
        case .started: mapped = .keyboardCommandStarted
        case .commandDown: mapped = .keyboardCommandDown
        case .keyDown: mapped = .keyboardKeyDown
        case .returned: mapped = .keyboardCommandReturned
        }
        diagnostics?.mark(mapped)
    }
}
