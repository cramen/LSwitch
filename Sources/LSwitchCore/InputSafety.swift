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

    public func isCurrent() -> Bool {
        guard !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == applicationPID,
              let current = AXTextConverter().focusedElement(),
              CFEqual(element, current), !InputSafety.isProtected(current) else { return false }
        return true
    }
}

/// Проверяется до чтения текста и до любого взаимодействия с clipboard.
@MainActor
public enum InputSafety {
    public static func captureTarget() -> InputTarget? {
        guard !IsSecureEventInputEnabled(),
              let application = NSWorkspace.shared.frontmostApplication,
              let element = AXTextConverter().focusedElement(),
              !isProtected(element) else { return nil }
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
