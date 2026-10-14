import AppKit
import ApplicationServices
import Foundation

/// Системная граница clipboard-операции. Тесты подменяют фокус, клавиши, время и pasteboard.
@MainActor
struct ClipboardEnvironment {
    typealias TextState = (text: String, selection: NSRange)

    struct Context {
        var isValid: () -> Bool
        var selectedText: () -> String?
        var readState: () -> TextState? = { nil }
        var setSelection: (NSRange) -> Bool = { _ in false }
    }

    var captureContext: () -> Context?
    var prepare: (@escaping @MainActor () -> Bool) -> Void = { _ in }
    var capture: () -> PasteboardSnapshot
    var restore: (PasteboardSnapshot) -> Void
    var changeCount: () -> Int
    var string: () -> String?
    var write: (String) -> (succeeded: Bool, changeCount: Int)
    var send: (ClipboardCommand, @escaping @MainActor () -> Bool) async -> Bool
    var commitPaste: (
        @escaping @MainActor () -> Bool, @escaping @MainActor () -> Bool, @escaping @MainActor () -> Bool
    ) -> MenuCommand.Outcome = { _, _, _ in .unavailable }
    var sleep: (TimeInterval) async -> Void

    static func live(pasteboard: NSPasteboard) -> ClipboardEnvironment {
        ClipboardEnvironment(
            captureContext: { makeContext() },
            prepare: { isValid in
                guard isValid(),
                      let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
                MenuCommand.prepare(targetPID: targetPID, isValid: isValid)
            },
            capture: { PasteboardService.capture(from: pasteboard) },
            restore: { PasteboardService.restore($0, to: pasteboard) },
            changeCount: { pasteboard.changeCount },
            string: { pasteboard.string(forType: .string) },
            write: {
                let ownedCount = pasteboard.clearContents()
                return (pasteboard.setString($0, forType: .string), ownedCount)
            },
            send: { command, isValid in
                guard isValid(),
                      let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
                switch MenuCommand.invoke(command, targetPID: targetPID, isValid: isValid) {
                case .performed: return isValid()
                case .failed: return false
                case .unavailable:
                    return await KeyboardEmitter.send(command, targetPID: targetPID, isValid: isValid)
                }
            },
            commitPaste: { select, check, isValid in commit(select: select, check: check, isValid: isValid) },
            sleep: { delay in
                guard delay > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        )
    }

    private static func commit(
        select: @escaping @MainActor () -> Bool,
        check: @escaping @MainActor () -> Bool,
        isValid: @escaping @MainActor () -> Bool
    ) -> MenuCommand.Outcome {
        guard isValid(),
              let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return .failed }
        return MenuCommand.pasteAfterSelection(
            targetPID: targetPID, select: select, afterSelectionCheck: check, isValid: isValid
        )
    }

    private static func makeContext() -> Context? {
        guard let target = InputSafety.captureTarget() else { return nil }
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
        })
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
