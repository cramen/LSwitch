import Foundation
@testable import LSwitchCore

/// Полностью RAM-модель: ни UI, ни CGEvent post, ни General pasteboard.
@MainActor
final class UnicodeTestEditor {
    enum Insertion { case normal, ignored, partial, selected, delayed }

    var text: String
    var selection: NSRange
    var document = "fixture:one"
    var source = UnicodeInputSource(identifier: "com.apple.keylayout.ABC", isKeyboardLayout: true)
    var provenance = UnicodeTextSnapshot.Provenance.chromiumTextControl
    var characterCount: Int?
    var contextValid = true
    var requestValid = true
    var cleanupValid = true
    var postAllowed = true
    var prepareAllowed = true
    var insertion = Insertion.normal
    var automatic = AutomaticTextContext.prose
    var selectionDelay = 0
    var selectionPrefixCount: Int?
    var ignoreSelection = false
    var commands: [UnicodeEnvironment.SelectionCommand] = []
    var pending: [(due: Int, command: UnicodeEnvironment.SelectionCommand)] = []
    var pendingText: (due: Int, value: String)?
    var pauses = 0
    var reads = 0
    var downCount = 0
    var upCount = 0
    var prepares = 0
    var beginCount = 0
    var onRead: (() -> Void)?
    var onPause: ((Int) -> Void)?
    var onDown: (() -> Void)?
    var onPrepare: (() -> Void)?
    var beforePacketCheck: (() -> Void)?
    var afterSelectionCommand: ((UnicodeEnvironment.SelectionCommand) -> Void)?
    var selectionPreflights = 0
    var selectionPostflights = 0

    init(_ text: String) {
        self.text = text
        self.selection = NSRange(location: text.utf16.count, length: 0)
    }

    func request(word: String = "ghbdtn", tail: String = " ", manual: Bool = false) -> ConversionRequest {
        ConversionRequest(
            expectedWord: word, trailingText: tail, sourceLayout: source?.layout, useSelection: manual,
            beginMutation: { self.beginCount += 1; return self.requestValid },
            canCleanup: { self.cleanupValid }, isValid: { self.requestValid }
        )
    }

    func converter() -> UnicodeTextConverter {
        UnicodeTextConverter(environment: UnicodeEnvironment(
            captureContext: {
                UnicodeEnvironment.Context(
                    processID: 123, isValid: { self.contextValid }, snapshot: { self.snapshot() },
                    automaticContext: { self.automatic }, documentIdentity: { self.document }
                )
            }, activeSource: { self.source }, canPost: { self.postAllowed }, prepare: { text, _ in
                self.prepares += 1
                self.onPrepare?()
                guard self.prepareAllowed else { return nil }
                var consumed = false
                return UnicodePreparedPacket { check in
                    self.beforePacketCheck?()
                    guard !consumed, check() else { return false }
                    consumed = true
                    self.downCount += 1
                    self.insert(text)
                    self.onDown?()
                    self.upCount += 1
                    return true
                }
            }, sendSelection: { command, _, before, after in
                self.selectionPreflights += 1
                guard before() else { return false }
                self.commands.append(command)
                if self.selectionDelay > 0 || !self.pending.isEmpty {
                    let due = self.pending.last?.due ?? (self.pauses + self.selectionDelay)
                    self.pending.append((due, command))
                } else {
                    self.apply(command)
                }
                self.afterSelectionCommand?(command)
                self.selectionPostflights += 1
                return after()
            }, pause: { self.advanceReceiver() }
        ))
    }

    func advanceReceiver() {
        pauses += 1
        onPause?(pauses)
        if let inserted = pendingText, inserted.due <= pauses {
            pendingText = nil
            type(inserted.value)
        }
        while let first = pending.first, first.due <= pauses {
            pending.removeFirst()
            apply(first.command)
        }
    }

    func snapshot() -> UnicodeTextSnapshot {
        reads += 1
        let snapshot = UnicodeTextSnapshot(text: text, selection: selection,
                                           characterCount: characterCount ?? text.utf16.count,
                                           coordinateText: text,
                                           provenance: provenance)
        onRead?()
        return snapshot
    }

    func type(_ value: String) {
        guard let range = Range(selection, in: text) else { return }
        text.replaceSubrange(range, with: value)
        selection = NSRange(location: selection.location + value.utf16.count, length: 0)
    }

    private func insert(_ value: String) {
        guard insertion != .ignored else { return }
        if insertion == .delayed {
            pendingText = (pauses + 3, value)
            return
        }
        let location = selection.location
        let inserted = insertion == .partial ? String(value.prefix(2)) : value
        type(inserted)
        if insertion == .selected { selection = NSRange(location: location, length: inserted.utf16.count) }
    }

    private func apply(_ command: UnicodeEnvironment.SelectionCommand) {
        switch command {
        case .select(let count):
            guard !ignoreSelection else { return }
            let actual = selectionPrefixCount ?? count
            let before = (text as NSString).substring(to: selection.location)
            let units = String(before.suffix(actual)).utf16.count
            selection = NSRange(location: selection.location - units, length: units)
        case .collapse:
            if selection.length > 0 {
                selection = NSRange(location: NSMaxRange(selection), length: 0)
            } else {
                selection = NSRange(location: min(text.utf16.count, selection.location + 1), length: 0)
            }
        }
    }
}
