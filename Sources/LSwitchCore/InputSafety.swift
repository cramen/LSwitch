import AppKit
import ApplicationServices
import Carbon

/// Снимок адресата: объект AX может принадлежать WebContent-процессу, поэтому
/// PID активного приложения проверяется отдельно от идентичности самого поля.
@MainActor
public struct InputTarget {
    public let element: AXUIElement
    private let applicationPID: pid_t

    fileprivate init(element: AXUIElement, applicationPID: pid_t) {
        self.element = element
        self.applicationPID = applicationPID
    }

    public var invalidationReason: ConversionDiagnostics.Rejection? {
        if IsSecureEventInputEnabled() { return .secureInput }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == applicationPID else {
            return .applicationChanged
        }
        guard let current = AXTextConverter().focusedElement() else { return .focusedElementUnavailable }
        guard CFEqual(element, current) else { return .focusedElementChanged }
        return InputSafety.isProtected(current) ? .protectedField : nil
    }

    public func isCurrent(diagnostics: ConversionDiagnostics? = nil) -> Bool {
        guard let reason = invalidationReason else { return true }
        diagnostics?.reject(reason)
        return false
    }
}

/// Проверяется до чтения текста и до любого взаимодействия с clipboard.
@MainActor
public enum InputSafety {
    public static func captureTarget(diagnostics: ConversionDiagnostics? = nil) -> InputTarget? {
        guard !IsSecureEventInputEnabled() else {
            diagnostics?.reject(.secureInput)
            return nil
        }
        guard let application = NSWorkspace.shared.frontmostApplication else {
            diagnostics?.reject(.applicationChanged)
            return nil
        }
        guard let element = AXTextConverter().focusedElement() else {
            diagnostics?.reject(.focusedElementUnavailable)
            return nil
        }
        guard !isProtected(element) else {
            diagnostics?.reject(.protectedField)
            return nil
        }
        return InputTarget(element: element, applicationPID: application.processIdentifier)
    }

    static func isProtected(_ element: AXUIElement) -> Bool {
        if AXTextConverter.isSecureField(element) { return true }
        var protected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXProtectedContent" as CFString, &protected) == .success,
           let flag = protected as? Bool, flag { return true }
        return false
    }
}
