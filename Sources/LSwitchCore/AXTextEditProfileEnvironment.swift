import AppKit
import ApplicationServices
import Carbon
import Darwin
import Foundation

extension AXProfileEnvironment {
    /// Явный helper для проверенного TextEdit. Обычный AXTextConverter его не использует.
    static func textEditCandidate() -> Self {
        let access = SystemAXTextAccess()
        let context = AXTextEditContextReader(access: AXTextEditProfileEnvironment.contextAccess)
        let bounded = AXBoundedSnapshotAccess(count: {
            AXTextEditProfileEnvironment.attribute(kAXNumberOfCharactersAttribute, $0) as? Int
        }, text: { AXTextEditProfileEnvironment.string(in: $0, range: $1) },
        selection: { access.selection(in: $0) })
        return .init(activeSource: { UnicodeInputSource.current() },
                     focusedElement: { access.focusedElement() },
                     isProtected: { AXTextEditProfileEnvironment.isProtected($0) },
                     context: { context.context($0) }, snapshot: { element, canRead in
            bounded.read(element, canRead: canRead)
        }, foregroundProcessID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                     boundedSnapshot: bounded)
    }
}

@MainActor
private enum AXTextEditProfileEnvironment {
    static var contextAccess: AXTextEditContextAccess {
        .init(processID: processID, processIdentity: { SystemProcessIdentity.read(processID: $0) },
              application: application, versions: versions, elementMetadata: elementMetadata,
              windowDocument: windowDocument)
    }

    private static func processID(_ element: AXUIElement) -> Int32? {
        var processID: pid_t = 0
        return AXUIElementGetPid(element, &processID) == .success ? processID : nil
    }

    private static func application(_ processID: Int32) -> AXProfileApplicationIdentity? {
        guard let application = NSRunningApplication(processIdentifier: processID),
              let identifier = application.bundleIdentifier, let url = application.bundleURL else { return nil }
        return .init(bundleIdentifier: identifier, bundleURL: url)
    }

    private static func versions(_ url: URL) -> AXProfileVersionMetadata? {
        guard let bundle = Bundle(url: url),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let systemBuild = Self.systemBuild() else { return nil }
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(system.majorVersion).\(system.minorVersion)"
        guard system.patchVersion == 0 else { return nil }
        return .init(applicationVersion: version, applicationBuild: build,
                     systemVersion: systemVersion, systemBuild: systemBuild)
    }

    private static func elementMetadata(_ element: AXUIElement) -> AXTextEditElementMetadata? {
        guard let values = attributeValues(AXTextEditElementMetadata.attributes, in: element) else { return nil }
        return AXTextEditElementMetadata.decode(values)
    }

    static func isProtected(_ element: AXUIElement) -> Bool {
        guard !IsSecureEventInputEnabled() else { return true }
        let values = attributeValues(AXProfileProtectionMetadata.attributes, in: element)
        return AXProfileProtectionMetadata.isProtected(values) || IsSecureEventInputEnabled()
    }

    private static func attributeValues(_ names: [String], in element: AXUIElement) -> [CFTypeRef]? {
        SystemAXTextAccess.limitMessaging(element)
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element, names as CFArray, [], &values
        ) == .success, let values, CFArrayGetCount(values) == names.count else { return nil }
        var result: [CFTypeRef] = []
        for index in 0..<names.count {
            guard let value = CFArrayGetValueAtIndex(values, index) else { return nil }
            result.append(Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue())
        }
        return result
    }

    private static func windowDocument(_ window: AXUIElement) -> AXProfileDocumentValue {
        SystemAXTextAccess.limitMessaging(window)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &value)
        if result == .noValue { return .missing }
        guard result == .success, let document = value as? String else { return .unavailable }
        return .value(document)
    }

    static func attribute(_ name: String, _ element: AXUIElement) -> CFTypeRef? {
        SystemAXTextAccess.limitMessaging(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(in element: AXUIElement, range: NSRange) -> String? {
        guard range.location == 0, range.length >= 0,
              range.length <= AXProfileSnapshot.maximumUTF16Units else { return nil }
        var requested = CFRange(location: 0, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &requested) else { return nil }
        SystemAXTextAccess.limitMessaging(element)
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value
        ) == .success else { return nil }
        return value as? String
    }

    private static func systemBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1, size < 256 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }
}
