import Foundation

/// Отказ известного профиля выполняется до создания AX-контекста и любых payload reads.
@MainActor
struct ClipboardApplicationPolicy {
    private let testApplicationBundleID: String?

    init() {
        self.testApplicationBundleID = nil
    }

    #if DEBUG
    init(keyboardOnly: Bool, forceCopyForAcceptance: Bool, testApplicationBundleID: String?) {
        self.testApplicationBundleID = keyboardOnly && forceCopyForAcceptance ? testApplicationBundleID : nil
    }
    #endif

    func capture(bundleID: String?, makeContext: () -> ClipboardEnvironment.Context?) -> ClipboardEnvironment.Context? {
        if let reason = rejection(bundleID: bundleID) {
            return ClipboardEnvironment.Context(
                isValid: { false }, selectedText: { nil }, safetyFailure: { reason }
            )
        }
        return makeContext()
    }

    private func rejection(bundleID: String?) -> ConversionDiagnostics.Rejection? {
        #if DEBUG
        if let testApplicationBundleID, testApplicationBundleID == bundleID { return nil }
        #endif
        return AppProfiles.clipboardRejection(bundleID: bundleID)
    }
}
