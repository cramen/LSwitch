import AppKit
import ApplicationServices
import Darwin
import Foundation

extension AXProfileEnvironment {
    /// Явный helper для проверенного TextEdit. Обычный AXTextConverter его не использует.
    static func textEditCandidate() -> Self {
        let access = SystemAXTextAccess()
        return .init(activeSource: { UnicodeInputSource.current() },
                     focusedElement: { access.focusedElement() }, isProtected: { access.isProtected($0) },
                     context: { AXTextEditProfileEnvironment.context($0) }, snapshot: { element, canRead in
            AXProfileSnapshotReader(readCount: {
                AXTextEditProfileEnvironment.attribute(kAXNumberOfCharactersAttribute, element) as? Int
            }, readText: { range in
                AXTextEditProfileEnvironment.string(in: element, range: range)
            }, readSelection: { access.selection(in: element) }).read(canRead: canRead)
        })
    }
}

@MainActor
private enum AXTextEditProfileEnvironment {
    static func context(_ element: AXUIElement) -> AXProfileContext? {
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success,
              let process = SystemProcessIdentity.read(processID: processID),
              let application = NSRunningApplication(processIdentifier: processID),
              application.bundleIdentifier == "com.apple.TextEdit", let url = application.bundleURL,
              let bundle = Bundle(url: url),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let windowValue = attribute(kAXWindowAttribute, element),
              CFGetTypeID(windowValue) == AXUIElementGetTypeID(),
              let role = attribute(kAXRoleAttribute, element) as? String,
              let document = SystemAutomaticTextContext.documentIdentity(in: element),
              let systemBuild = Self.systemBuild() else { return nil }
        // swiftlint:disable:next force_cast
        let window = windowValue as! AXUIElement
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == processID else { return nil }
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(system.majorVersion).\(system.minorVersion)"
        guard system.patchVersion == 0 else { return nil }
        return .init(process: process, window: window, document: document,
                     bundleIdentifier: "com.apple.TextEdit", applicationVersion: version, applicationBuild: build,
                     systemVersion: systemVersion, systemBuild: systemBuild, role: role)
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
