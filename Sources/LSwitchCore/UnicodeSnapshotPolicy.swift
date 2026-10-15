import Foundation

/// Exact Chromium 155: AX kValue обрезается на 10k UTF-8 bytes, до scalar boundary.
enum UnicodeSnapshotPolicy {
    static let exclusiveValueByteLimit = 9_997
    static let testedVersion = "155.0.8059.80"

    static func permitsValue(_ text: String) -> Bool {
        text.utf8.prefix(exclusiveValueByteLimit).count < exclusiveValueByteLimit
    }

    static func permitsProvider(
        bundleID: String?, version: String?, role: String?, editableRoot: Bool, documentRoot: Bool
    ) -> Bool {
        bundleID == "com.google.Chrome" && version == testedVersion
            && role == "AXTextArea" && editableRoot && documentRoot
    }
}
