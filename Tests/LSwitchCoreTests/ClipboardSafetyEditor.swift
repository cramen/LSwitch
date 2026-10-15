import ApplicationServices
import Foundation
@testable import LSwitchCore

/// Модель отдельно подтверждает доставку token, а не выводит ACK из AXError/readback.
@MainActor
final class ClipboardSafetyEditor {
    var text: String
    var selection: NSRange
    var clipboard = "original clipboard"
    var count = 1
    var captures = 0
    var writes = 0
    var restores = 0
    var preparations = 0
    var stateReads = 0
    var selectionWrites = 0
    var commands: [ClipboardCommand] = []
    var completed = Set<ConversionSafetySubmissionToken>()
    var unconfirmedKinds: [ConversionSafetySubmissionKind] = []
    var bound = true
    var current = true
    var processAlive = true
    var exposesState = true
    var missingAfterSelection = false
    var selectionStatus: AXError = .success
    var selectionMethod: ClipboardEnvironment.SelectionMethod = .accessibility
    var failBeforePaste = false
    var keepPastedSelection = false
    var deferredSelection: (range: NSRange, token: ConversionSafetySubmissionToken)?
    var deferFirstSelection = false
    var onWrite: () -> Void = {}
    var onRead: () -> Void = {}
    var onSubmit: (ConversionSafetySubmissionToken) -> Void = { _ in }

    init(_ text: String = "ghbdtn ") {
        self.text = text
        self.selection = NSRange(location: text.utf16.count, length: 0)
    }

    var state: ClipboardEnvironment.TextState? {
        stateReads += 1
        onRead()
        return exposesState ? (text, selection) : nil
    }

    var selectedText: String? {
        guard let range = Range(selection, in: text) else { return nil }
        return String(text[range])
    }

    func converter(forceCopy: Bool = false) -> ClipboardConverter {
        var configuration = ClipboardConverter.Configuration()
        configuration.forceCopyForAcceptance = forceCopy
        return ClipboardConverter(configuration: configuration, environment: environment())
    }

    func environment() -> ClipboardEnvironment {
        ClipboardEnvironment(
            captureContext: { self.makeContext() }, prepare: { _ in self.preparations += 1 },
            capture: {
                self.captures += 1
                return .captured(.init(items: [.init(dataByType: ["test": Data(self.clipboard.utf8)])]),
                                 changeCount: self.count)
            }, restore: { snapshot in
                guard let item = snapshot.items.first, let data = item.dataByType["test"], let data,
                      let value = String(data: data, encoding: .utf8) else { return }
                self.restores += 1
                self.clipboard = value
                self.count += 1
            }, changeCount: { self.count }, string: { self.clipboard },
            write: { self.write($0) }, send: { _, _ in false },
            sleep: { _ in }, receiverContract: receiverContract(),
            writeTracked: { value, valid in valid() ? self.write(value) : nil },
            sendTracked: { command, valid, hooks in self.send(command, valid: valid, hooks: hooks) },
            commitPasteTracked: { select, check, valid, hooks in
                guard await select(), check(), valid(), !self.failBeforePaste else { return .failed }
                return self.send(.paste, valid: valid, hooks: hooks) ? .performed : .failed
            }
        )
    }

    private func makeContext() -> ClipboardEnvironment.Context {
        ClipboardEnvironment.Context(isValid: { self.current }, selectedText: { self.selectedText },
                                     readState: { self.state }, prepareSelection: { range in
            AXPreparedWrite { token in
                guard let token else { return .failure }
                self.onSubmit(token)
                self.selectionWrites += 1
                if self.deferFirstSelection, self.selectionWrites == 1 {
                    self.deferredSelection = (range, token)
                } else {
                    self.selection = range
                    self.complete(token, kind: range.length > 0 ? .selection : .restoreSelection)
                }
                if range.length > 0, self.missingAfterSelection { self.exposesState = false }
                return self.selectionWrites == 1 ? self.selectionStatus : .success
            }
        }, selectionMethod: selectionMethod)
    }

    private func receiverContract() -> ClipboardReceiverContract {
        .init(bind: { identity, operation in
            guard self.bound else { return nil }
            return .init(contextIdentity: identity, operation: operation, isCurrent: { self.current },
                         canBalance: { self.processAlive }, completion: { reply, _ in
                self.completed.contains(reply.submission) ? .receiverCompleted : .unresolved
            })
        })
    }

    private func write(_ value: String) -> (succeeded: Bool, changeCount: Int) {
        writes += 1
        clipboard = value
        count += 1
        let owned = count
        onWrite()
        return (true, owned)
    }

    private func complete(_ token: ConversionSafetySubmissionToken, kind: ConversionSafetySubmissionKind) {
        if !unconfirmedKinds.contains(kind) { completed.insert(token) }
    }

    private func send(
        _ command: ClipboardCommand, valid: () -> Bool, hooks: ClipboardDispatchHooks
    ) -> Bool {
        guard valid(), let token = hooks.beforeSend(command.submissionKind) else { return false }
        onSubmit(token)
        commands.append(command)
        switch command {
        case .selectCharacters(let count):
            selection = NSRange(location: selection.location - count, length: count)
            if missingAfterSelection { exposesState = false }
        case .selectWord:
            selection = NSRange(location: 0, length: text.utf16.count)
        case .copy:
            clipboard = selectedText ?? ""
            count += 1
        case .paste:
            if let range = Range(selection, in: text) {
                text.replaceSubrange(range, with: clipboard)
                let start = selection.location
                selection = keepPastedSelection
                    ? NSRange(location: start, length: clipboard.utf16.count)
                    : NSRange(location: start + clipboard.utf16.count, length: 0)
            }
        case .collapseSelection:
            selection = NSRange(location: NSMaxRange(selection), length: 0)
        }
        complete(token, kind: command.submissionKind)
        hooks.didReturn(.init(submission: token, transport: .keyboard, status: nil))
        return true
    }
}
