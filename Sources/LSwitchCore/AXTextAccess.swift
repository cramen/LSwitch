import ApplicationServices
import Carbon
import Foundation

/// Системные обращения отделены от операции для проверки отказов без реального UI.
@MainActor
protocol AXTextAccess {
    func focusedElement() -> AXUIElement?
    func isProtected(_ element: AXUIElement) -> Bool
    func text(in element: AXUIElement) -> String?
    func selection(in element: AXUIElement) -> NSRange?
    func canReplaceText(in element: AXUIElement) -> Bool
    func canSetSelection(in element: AXUIElement) -> Bool
    func replaceSelectedText(_ text: String, in element: AXUIElement) -> Bool
    func setSelection(_ range: NSRange, in element: AXUIElement) -> Bool
}

@MainActor
struct SystemAXTextAccess: AXTextAccess {
    static func limitMessaging(_ element: AXUIElement) {
        // Зависшее приложение не должно надолго удерживать пользовательский ввод.
        AXUIElementSetMessagingTimeout(element, 0.1)
    }

    func focusedElement() -> AXUIElement? {
        guard let value = attribute(kAXFocusedUIElementAttribute, in: AXUIElementCreateSystemWide()),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    static func isSecureField(_ element: AXUIElement) -> Bool {
        let access = SystemAXTextAccess()
        let subrole = access.attribute(kAXSubroleAttribute, in: element) as? String
        let protected = access.attribute("AXProtectedContent", in: element) as? Bool
        return subrole == "AXSecureTextField" || protected == true
    }

    func isProtected(_ element: AXUIElement) -> Bool {
        IsSecureEventInputEnabled() || Self.isSecureField(element)
    }

    func text(in element: AXUIElement) -> String? {
        attribute(kAXValueAttribute, in: element) as? String
    }

    func selection(in element: AXUIElement) -> NSRange? {
        guard let value = attribute(kAXSelectedTextRangeAttribute, in: element),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    func canReplaceText(in element: AXUIElement) -> Bool {
        isSettable(kAXSelectedTextAttribute, in: element)
    }

    func canSetSelection(in element: AXUIElement) -> Bool {
        isSettable(kAXSelectedTextRangeAttribute, in: element)
    }

    func replaceSelectedText(_ text: String, in element: AXUIElement) -> Bool {
        Self.limitMessaging(element)
        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success
    }

    func setSelection(_ range: NSRange, in element: AXUIElement) -> Bool {
        Self.limitMessaging(element)
        var value = CFRange(location: range.location, length: range.length)
        guard let axValue = AXValueCreate(.cfRange, &value) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue) == .success
    }

    private func attribute(_ name: String, in element: AXUIElement) -> CFTypeRef? {
        Self.limitMessaging(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func isSettable(_ name: String, in element: AXUIElement) -> Bool {
        Self.limitMessaging(element)
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }
}
