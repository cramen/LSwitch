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
    var protectedField = false
    var requestValid = true
    var leaseValid = true
    var revision = 0
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
    var valueReads = 0
    var coordinateReads = 0
    var identityReads = 0
    var currentChecks = 0
    var downCount = 0
    var upCount = 0
    var prepares = 0
    var beginCount = 0
    var onRead: (() -> Void)?
    var afterMetadataRead: (() -> Void)?
    var afterValueRead: (() -> Void)?
    var onIdentityRead: (() -> Void)?
    var onPause: ((Int) -> Void)?
    var onDown: (() -> Void)?
    var onPrepare: (() -> Void)?
    var beforePacketCheck: (() -> Void)?
    var afterSelectionCommand: ((UnicodeEnvironment.SelectionCommand) -> Void)?
    var omitSelectionAfterCallback = false
    var selectionAfterCallbackCount = 1
    var selectReturnValue = true
    var beforeRepeatedSelectionAfter: (() -> Void)?
    var selectionPreflights = 0
    var selectionPostflights = 0

    init(_ text: String) {
        self.text = text
        self.selection = NSRange(location: text.utf16.count, length: 0)
    }

    func request(word: String = "ghbdtn", tail: String = " ", manual: Bool = false) -> ConversionRequest {
        let started = revision
        return ConversionRequest(
            expectedWord: word, trailingText: tail, sourceLayout: source?.layout, useSelection: manual,
            beginMutation: {
                self.beginCount += 1
                return self.requestValid && self.leaseValid && self.revision == started
            },
            canCleanup: { self.cleanupValid },
            isValid: { self.requestValid && self.leaseValid && self.revision == started }
        )
    }

    func converter() -> UnicodeTextConverter {
        UnicodeTextConverter(environment: UnicodeEnvironment(
            captureContext: {
                UnicodeEnvironment.Context(
                    processID: 123, isCurrent: { self.isCurrent() }, rawSnapshot: { self.snapshot(canReadText: $0) },
                    automaticContext: { self.automatic }, rawDocumentIdentity: { self.readIdentity() }
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
                self.sendSelection(command, before: before, after: after)
            }, pause: { self.advanceReceiver() }
        ))
    }

    private func sendSelection(
        _ command: UnicodeEnvironment.SelectionCommand, before: () -> Bool, after: () -> Bool
    ) -> Bool {
        selectionPreflights += 1
        guard before() else { return false }
        commands.append(command)
        if selectionDelay > 0 || !pending.isEmpty {
            let due = pending.last?.due ?? (pauses + selectionDelay)
            pending.append((due, command))
        } else {
            apply(command)
        }
        afterSelectionCommand?(command)
        let selecting: Bool
        if case .select = command { selecting = true } else { selecting = false }
        if selecting && omitSelectionAfterCallback { return selectReturnValue }
        let count = selecting ? max(1, selectionAfterCallbackCount) : 1
        for index in 0..<count {
            if index > 0 { beforeRepeatedSelectionAfter?() }
            selectionPostflights += 1
            guard after() else { return false }
        }
        return !selecting || selectReturnValue
    }

    func isCurrent() -> Bool {
        currentChecks += 1
        return contextValid && !protectedField
    }

    func readIdentity() -> String? {
        identityReads += 1
        onIdentityRead?()
        return document
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

    func snapshot(canReadText: UnicodeEnvironment.Context.TextReadPermission) -> UnicodeTextSnapshot? {
        reads += 1
        afterMetadataRead?()
        guard canReadText() else { return nil }
        valueReads += 1
        let value = text
        let selected = selection
        afterValueRead?()
        guard canReadText() else { return nil }
        coordinateReads += 1
        let snapshot = UnicodeTextSnapshot(text: value, selection: selected,
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
