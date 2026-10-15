import AppKit
import ApplicationServices
import Foundation

/// Только метаданные текущего AX-элемента; содержимое файла на диске не читается.
@MainActor
enum SystemAutomaticTextContext {
    private enum Document {
        case file(String), missing, unavailable

        var url: String? {
            if case .file(let url) = self { return url }
            return nil
        }
    }

    static func read(in element: AXUIElement) -> AutomaticTextContext {
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success,
              let bundleID = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier else {
            return .unknown
        }
        let role = attribute(kAXRoleAttribute, in: element) as? String
        if AutomaticDocumentPolicy.isBrowser(bundleID) {
            return AutomaticDocumentPolicy.context(
                bundleID: bundleID, role: role, document: nil, characterCount: nil
            )
        }
        var document = readDocument(in: element)
        var untitledIdentity: String?
        if document.url == nil, role == kAXTextAreaRole, AutomaticDocumentPolicy.isDocumentEditor(bundleID),
           let window = attribute(kAXWindowAttribute, in: element),
           CFGetTypeID(window) == AXUIElementGetTypeID() {
            // swiftlint:disable:next force_cast
            let documentWindow = window as! AXUIElement
            document = readDocument(in: documentWindow)
            if bundleID == "com.apple.TextEdit", case .missing = document {
                untitledIdentity = "untitled:\(processID):\(CFHash(documentWindow))"
            }
        }
        let preliminary = AutomaticDocumentPolicy.context(
            bundleID: bundleID, role: role, document: document.url, characterCount: nil,
            untitledDocumentIdentity: untitledIdentity
        )
        guard case .source(let language, let identity, _) = preliminary else { return preliminary }
        // Виртуализированный editor может отдавать только окно строк с относительными
        // range/count. Без адаптера, подтверждающего начало документа, лексер опасен.
        guard bundleID == "com.apple.TextEdit" else { return .unverifiedSource(document: identity) }
        let count = attribute(kAXNumberOfCharactersAttribute, in: element) as? Int
        return .source(language: language, document: identity, characterCount: count)
    }

    /// Для manual/undo нужна только identity; язык, count и lexical policy не читаются.
    static func documentIdentity(in element: AXUIElement) -> String? {
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success,
              let bundleID = NSRunningApplication(processIdentifier: processID)?.bundleIdentifier,
              !AutomaticDocumentPolicy.isBrowser(bundleID) else { return nil }
        let role = attribute(kAXRoleAttribute, in: element) as? String
        guard role == kAXTextAreaRole || role == kAXTextFieldRole else { return nil }
        if let identity = normalizedDocument(readDocument(in: element).url) { return identity }
        guard role == kAXTextAreaRole, AutomaticDocumentPolicy.isDocumentEditor(bundleID),
              let window = attribute(kAXWindowAttribute, in: element),
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let documentWindow = window as! AXUIElement
        let document = readDocument(in: documentWindow)
        if let identity = normalizedDocument(document.url) { return identity }
        if bundleID == "com.apple.TextEdit", case .missing = document {
            return "untitled:\(processID):\(CFHash(documentWindow))"
        }
        return nil
    }

    private static func normalizedDocument(_ value: String?) -> String? {
        guard let value, let url = URL(string: value), url.isFileURL, url.path.hasPrefix("/") else { return nil }
        return url.absoluteString
    }

    private static func readDocument(in element: AXUIElement) -> Document {
        SystemAXTextAccess.limitMessaging(element)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXDocumentAttribute as CFString, &value)
        if result == .noValue { return .missing }
        guard result == .success, let document = value as? String else { return .unavailable }
        return .file(document)
    }

    private static func attribute(_ name: String, in element: AXUIElement) -> CFTypeRef? {
        SystemAXTextAccess.limitMessaging(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
