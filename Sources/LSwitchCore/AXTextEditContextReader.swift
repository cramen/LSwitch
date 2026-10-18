import ApplicationServices
import Foundation

enum AXProfileDocumentValue: Equatable {
    case value(String), missing, unavailable

    var fileIdentity: String? {
        guard case .value(let value) = self, let url = URL(string: value), url.isFileURL,
              url.path.hasPrefix("/") else { return nil }
        return url.absoluteString
    }

    /// CFNull и неизвестная ошибка не означают noValue; особенно это важно для untitled окна.
    static func batchValue(_ value: CFTypeRef) -> Self? {
        if let text = value as? String { return .value(text) }
        if CFGetTypeID(value) == CFNullGetTypeID() { return .unavailable }
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let wrapped = value as! AXValue
        var error = AXError.failure
        guard AXValueGetType(wrapped) == .axError, AXValueGetValue(wrapped, .axError, &error) else { return nil }
        return error == .noValue ? .missing : .unavailable
    }
}

struct AXTextEditElementMetadata {
    static let attributes = [kAXRoleAttribute, kAXWindowAttribute, kAXDocumentAttribute]
    let role: String
    let window: AXUIElement
    let document: AXProfileDocumentValue

    /// Порядок соответствует фиксированному запросу Role, Window, Document; частичный batch отвергается.
    static func decode(_ values: [CFTypeRef]) -> Self? {
        guard values.count == 3, let role = values[0] as? String,
              CFGetTypeID(values[1]) == AXUIElementGetTypeID(),
              let document = AXProfileDocumentValue.batchValue(values[2]) else { return nil }
        // swiftlint:disable:next force_cast
        return .init(role: role, window: values[1] as! AXUIElement,
                     document: document)
    }
}

struct AXProfileApplicationIdentity: Equatable {
    let bundleIdentifier: String
    let bundleURL: URL
}

struct AXProfileVersionMetadata {
    let applicationVersion: String
    let applicationBuild: String
    let systemVersion: String
    let systemBuild: String
}

/// Подменяемые metadata reads. Здесь нет AXValue текста, selectedText или чтения содержимого документа.
@MainActor
struct AXTextEditContextAccess {
    let processID: (AXUIElement) -> Int32?
    let processIdentity: (Int32) -> RecoveryProcessIdentity?
    let application: (Int32) -> AXProfileApplicationIdentity?
    let versions: (URL) -> AXProfileVersionMetadata?
    let elementMetadata: (AXUIElement) -> AXTextEditElementMetadata?
    let windowDocument: (AXUIElement) -> AXProfileDocumentValue
}

@MainActor
final class AXTextEditContextReader {
    private struct CachedVersions {
        let process: RecoveryProcessIdentity
        let application: AXProfileApplicationIdentity
        let versions: AXProfileVersionMetadata
    }

    private let access: AXTextEditContextAccess
    private var cached: CachedVersions?

    init(access: AXTextEditContextAccess) { self.access = access }

    func context(_ element: AXUIElement) -> AXProfileContext? {
        guard let processID = access.processID(element),
              let process = access.processIdentity(processID), process.processID == processID,
              let application = access.application(processID),
              application.bundleIdentifier == "com.apple.TextEdit" else {
            cached = nil
            return nil
        }
        guard let versions = versions(for: process, application: application),
              let metadata = access.elementMetadata(element),
              access.processID(metadata.window) == processID,
              let document = documentIdentity(metadata, processID: processID) else { return nil }
        return .init(process: process, window: metadata.window, document: document,
                     bundleIdentifier: application.bundleIdentifier,
                     applicationVersion: versions.applicationVersion, applicationBuild: versions.applicationBuild,
                     systemVersion: versions.systemVersion, systemBuild: versions.systemBuild, role: metadata.role)
    }

    private func versions(
        for process: RecoveryProcessIdentity, application: AXProfileApplicationIdentity
    ) -> AXProfileVersionMetadata? {
        if let cached, cached.process == process, cached.application == application { return cached.versions }
        cached = nil
        guard let versions = access.versions(application.bundleURL) else { return nil }
        cached = .init(process: process, application: application, versions: versions)
        return versions
    }

    private func documentIdentity(_ metadata: AXTextEditElementMetadata, processID: Int32) -> String? {
        guard metadata.role == kAXTextAreaRole || metadata.role == kAXTextFieldRole else { return nil }
        if let identity = metadata.document.fileIdentity { return identity }
        guard metadata.role == kAXTextAreaRole else { return nil }
        let document = access.windowDocument(metadata.window)
        if let identity = document.fileIdentity { return identity }
        if document == .missing { return "untitled:\(processID):\(CFHash(metadata.window))" }
        return nil
    }
}
