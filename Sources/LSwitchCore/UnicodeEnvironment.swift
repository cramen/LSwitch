import Foundation

/// Полнота относится к логическому полю, не просто к длине виртуализированного AX-окна.
struct UnicodeTextSnapshot {
    enum Provenance { case chromiumTextControl, unverified }
    let text: String
    let selection: NSRange
    let characterCount: Int?
    let coordinateText: String?
    let provenance: Provenance

    var isComplete: Bool {
        let length = text.utf16.count
        guard provenance == .chromiumTextControl, UnicodeSnapshotPolicy.permitsValue(text),
              let coordinateText, text.utf16.elementsEqual(coordinateText.utf16),
              characterCount == length, selection.location >= 0,
              selection.length >= 0, selection.location <= length,
              selection.length <= length - selection.location else { return false }
        return Range(selection, in: text) != nil
    }

    func matches(text expected: String, selection expectedSelection: NSRange) -> Bool {
        selection == expectedSelection && text.utf16.elementsEqual(expected.utf16)
    }
}

/// Эта граница не содержит ни pasteboard, ни Copy/Paste, ни AX-записи текста.
@MainActor
struct UnicodeEnvironment {
    enum SelectionCommand: Equatable { case select(Int), collapse }

    struct Context {
        let processID: pid_t
        var isValid: @MainActor @Sendable () -> Bool
        var snapshot: () -> UnicodeTextSnapshot?
        var automaticContext: @MainActor @Sendable () -> AutomaticTextContext
        var documentIdentity: @MainActor @Sendable () -> String?
    }

    var captureContext: () -> Context?
    var activeSource: () -> UnicodeInputSource?
    var canPost: () -> Bool
    var prepare: (String, pid_t) -> UnicodePreparedPacket?
    var sendSelection: (
        SelectionCommand, pid_t, @escaping @MainActor () -> Bool, @escaping @MainActor () -> Bool
    ) async -> Bool
    var pause: () async -> Void
}
