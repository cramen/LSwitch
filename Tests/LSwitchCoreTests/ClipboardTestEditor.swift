import Foundation
@testable import LSwitchCore

@MainActor
final class ClipboardEditor {
    var text: String
    var cursor: Int
    var selection: Range<Int>?
    var clipboard = "clipboard before"
    var count = 0
    var captures = 0
    var restores = 0
    var writes = 0
    var sleeps = 0
    var preparations = 0
    var stateReads = 0
    var exposesState = true
    var initialStateUnavailable = false
    var commitAvailable = true
    var commitReportsFailure = false
    var stateOverride: ClipboardEnvironment.TextState?
    var deferredPaste = false
    var rangeSettable = true
    var rangeWriteApplies = true
    var rangeWriteSucceeds = true
    var rangeWrites: [NSRange] = []
    var ignoreCollapseSelection = false
    var selectedTextAvailable = true
    var rejectedPasteClearsSelection = false
    var pendingPaste: String?
    var sleepDelays: [TimeInterval] = []
    var safe = true
    var current = true
    var requestValid = true
    var keepPastedSelection = false
    var rejectPaste = false
    var copyResults: [String?] = []
    var commands: [ClipboardCommand] = []
    var mutationEvents: [String] = []
    var onSleep: (Int) -> Void = { _ in }
    var onPrepare: () -> Void = {}
    var onWrite: () -> Void = {}
    var onReadState: (Int) -> Void = { _ in }
    var onRangeWrite: (NSRange) -> Void = { _ in }
    var beforeCommand: (ClipboardCommand) -> Void = { _ in }
    var afterCommand: (ClipboardCommand) -> Void = { _ in }

    init(text: String) {
        self.text = text
        self.cursor = text.count
    }

    var selectedText: String {
        guard let selection else { return "" }
        return String(Array(text)[selection])
    }

    var state: ClipboardEnvironment.TextState? {
        stateReads += 1
        onReadState(stateReads)
        guard exposesState, !(initialStateUnavailable && stateReads == 1) else { return nil }
        if let stateOverride { return stateOverride }
        let range = selection ?? cursor..<cursor
        let location = String(text.prefix(range.lowerBound)).utf16.count
        let length = String(Array(text)[range]).utf16.count
        return (text, NSRange(location: location, length: length))
    }

    func converter() -> ClipboardConverter {
        ClipboardConverter(environment: ClipboardEnvironment(
            captureContext: {
                guard self.safe else { return nil }
                return ClipboardEnvironment.Context(
                    isValid: { self.safe && self.current },
                    selectedText: { self.selectedTextAvailable ? self.selectedText : nil },
                    readState: { self.state }, setSelection: { self.setRange($0) }
                )
            },
            prepare: { isValid in
                guard isValid() else { return }
                self.preparations += 1
                self.onPrepare()
            },
            capture: {
                self.captures += 1
                return PasteboardSnapshot(items: [
                    .init(dataByType: ["text": Data(self.clipboard.utf8)])
                ])
            },
            restore: { snapshot in
                self.restores += 1
                if let item = snapshot.items.first, let data = item.dataByType["text"], let data {
                    self.updateClipboard(String(decoding: data, as: UTF8.self))
                }
            },
            changeCount: { self.count },
            string: { self.clipboard },
            write: {
                self.writes += 1
                self.updateClipboard($0)
                let ownedCount = self.count
                self.onWrite()
                return (true, ownedCount)
            },
            send: { command, isValid in self.deliver(command, isValid: isValid) },
            commitPaste: { select, check, isValid in self.commit(select: select, check: check, isValid: isValid) },
            sleep: { delay in
                self.sleepDelays.append(delay)
                self.sleeps += 1
                self.onSleep(self.sleeps)
            }
        ))
    }

    func updateClipboard(_ value: String) {
        clipboard = value
        count += 1
    }

    func type(_ value: String) {
        var characters = Array(text)
        let range = selection ?? cursor..<cursor
        characters.replaceSubrange(range, with: value)
        text = String(characters)
        cursor = range.lowerBound + value.count
        selection = nil
    }

    private func commit(select: () -> Bool, check: () -> Bool, isValid: () -> Bool) -> MenuCommand.Outcome {
        guard commitAvailable else { return .unavailable }
        let selected = select()
        let confirmed = check()
        guard selected, confirmed, isValid(), deliver(.paste, isValid: isValid) else { return .failed }
        return isValid() && !commitReportsFailure ? .performed : .failed
    }

    private func setRange(_ range: NSRange) -> Bool {
        guard rangeSettable else { return false }
        rangeWrites.append(range)
        guard rangeWriteApplies else { return rangeWriteSucceeds }
        guard let indices = Range(range, in: text) else { return false }
        let lower = text[..<indices.lowerBound].count
        let upper = text[..<indices.upperBound].count
        selection = range.length == 0 ? nil : lower..<upper
        cursor = upper
        onRangeWrite(range)
        return rangeWriteSucceeds
    }

    private func deliver(_ command: ClipboardCommand, isValid: () -> Bool) -> Bool {
        beforeCommand(command)
        guard isValid() else { return false }
        let sent = send(command)
        afterCommand(command)
        return sent
    }

    private func send(_ command: ClipboardCommand) -> Bool {
        commands.append(command)
        switch command {
        case .selectCharacters(let length):
            selection = max(0, cursor - length)..<cursor
        case .selectWord:
            let prefix = String(text.prefix(cursor))
            let length = prefix.split(separator: " ").last?.count ?? 0
            selection = max(0, cursor - length)..<cursor
        case .copy: copySelection()
        case .paste: pasteSelection()
        case .collapseSelection:
            if !ignoreCollapseSelection {
                cursor = selection?.upperBound ?? cursor
                selection = nil
            }
        }
        return true
    }

    private func copySelection() {
        if !copyResults.isEmpty {
            if let copied = copyResults.removeFirst() { updateClipboard(copied) }
        } else {
            updateClipboard(selectedText)
        }
    }

    private func pasteSelection() {
        if rejectPaste {
            if rejectedPasteClearsSelection {
                cursor = selection?.upperBound ?? cursor
                selection = nil
            }
            return
        }
        if deferredPaste {
            pendingPaste = clipboard
            return
        }
        let start = selection?.lowerBound ?? cursor
        type(clipboard)
        if keepPastedSelection { selection = start..<cursor }
    }
}
