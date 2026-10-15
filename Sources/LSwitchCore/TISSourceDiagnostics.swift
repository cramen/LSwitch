import Carbon
import Foundation
import os

#if DEBUG
/// Дополнительные TIS-чтения разрешены только на MainActor и только в DEBUG.
enum TISSourceDiagnostics {
    private static let logger = Logger(subsystem: "LSwitch", category: "TISDiagnostics")
    private static let builtinIDs: Set<String> = [
        "com.apple.keylayout.ABC", "com.apple.keylayout.US",
        "com.apple.keylayout.Russian", "com.apple.keylayout.RussianWin"
    ]

    @MainActor
    static func recordRead(layoutSourceID: String?) {
        let keyboardID = sourceID(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue())
        let line = "stage=read " + summary(keyboardSourceID: keyboardID, layoutSourceID: layoutSourceID)
        logger.notice("\(line, privacy: .public)")
    }

    @MainActor
    static func recordSwitch(stage: String, target: Layout, status: OSStatus) {
        let keyboardID = sourceID(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue())
        let layoutID = sourceID(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
        let line = "stage=\(stage) targetLayout=\(target.rawValue) status=\(status) accepted=\(status == noErr) "
            + summary(keyboardSourceID: keyboardID, layoutSourceID: layoutID)
        logger.notice("\(line, privacy: .public)")
    }

    static func summary(keyboardSourceID: String?, layoutSourceID: String?) -> String {
        let keyboard = keyboardSourceID.flatMap(LayoutManager.layout(forSourceID:))?.rawValue ?? "unknown"
        let layout = layoutSourceID.flatMap(LayoutManager.layout(forSourceID:))?.rawValue ?? "unknown"
        return "keyboardSource=\(safeID(keyboardSourceID)) keyboardCategory=\(keyboard)"
            + " layoutSource=\(safeID(layoutSourceID)) layoutCategory=\(layout)"
    }

    private static func safeID(_ identifier: String?) -> String {
        guard let identifier else { return "unavailable" }
        return builtinIDs.contains(identifier) ? identifier : "other"
    }

    @MainActor
    private static func sourceID(_ source: TISInputSource?) -> String? {
        guard let source, let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
#endif
