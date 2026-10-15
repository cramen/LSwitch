import CoreGraphics
import Foundation
@testable import LSwitchCore

/// RAM-приёмник подтверждает tokens в точке обработки, а не по Boolean отправителя или AX snapshot.
@MainActor
final class UnicodeSafetyEditor {
    enum Insertion { case normal, partial, ignored, selected }
    struct PendingSelection {
        let command: NativeSelectionCommand
        let token: ConversionSafetySubmissionToken
        let due: Int
    }

    var text: String
    var selection: NSRange
    var document = "fixture"
    var contextValid = true
    var balanceAllowed = true
    var exposesContract = true
    var characterCount: Int?
    var insertion = Insertion.normal
    var ignoreSelection = false
    var ignoreCollapse = false
    var partialSelection = false
    var selectionDelay = 0
    var completed = Set<ConversionSafetySubmissionToken>()
    var unconfirmedKinds: [ConversionSafetySubmissionKind] = []
    var commands: [NativeSelectionCommand] = []
    var pending: [PendingSelection] = []
    var reads = 0
    var prepares = 0
    var downCount = 0
    var upCount = 0
    var pauses = 0
    var onSelect: () -> Void = {}
    var onDown: () -> Void = {}
    var onRead: () -> Void = {}
    var onPause: () -> Void = {}
    private var currentToken: ConversionSafetySubmissionToken?
    private var kinds: [ConversionSafetySubmissionToken: ConversionSafetySubmissionKind] = [:]

    init(_ text: String = "ghbdtn ") {
        self.text = text
        selection = NSRange(location: text.utf16.count, length: 0)
    }

    func converter() -> UnicodeTextConverter {
        UnicodeTextConverter(environment: .init(
            captureContext: {
                .init(processID: 123, isCurrent: { self.contextValid }, rawSnapshot: { self.snapshot($0) },
                      automaticContext: { .prose }, rawDocumentIdentity: { self.document })
            }, activeSource: { .init(identifier: "com.apple.keylayout.ABC", isKeyboardLayout: true) },
            canPost: { true }, prepare: { self.packet($0, processID: $1) },
            sendSelection: { _, _, _, _ in false }, pause: { self.advance() }, receiverContract: contract(),
            sendSelectionTracked: { command, _, before, after, hooks in
                self.select(command, before: before, after: after, hooks: hooks)
            }
        ))
    }

    private func contract() -> UnicodeReceiverContract {
        .init(bind: { target, operation in
            guard self.exposesContract else { return nil }
            return .init(target: target, operation: operation, isCurrent: { self.contextValid },
                         canBalance: { self.balanceAllowed }, completion: { reply, _ in
                self.completed.contains(reply.submission) ? .receiverCompleted : .unresolved
            })
        })
    }

    private func snapshot(_ permission: UnicodeEnvironment.TextReadPermission) -> UnicodeTextSnapshot? {
        guard permission() else { return nil }
        reads += 1
        onRead()
        guard permission() else { return nil }
        return .init(text: text, selection: selection, characterCount: characterCount ?? text.utf16.count,
                     coordinateText: text, provenance: .chromiumTextControl)
    }

    private func packet(_ value: String, processID: pid_t) -> UnicodePreparedPacket? {
        prepares += 1
        guard let packet = UnicodeEventEmitter.prepare(value, targetPID: processID, delivery: { event, target in
            precondition(target == processID)
            self.receive(event, value: value)
        }) else { return nil }
        return .init(post: packet.post, postTracked: { check, hooks in
            packet.postTracked?(check, self.wrapped(hooks)) ?? false
        })
    }

    private func wrapped(_ hooks: ConversionDispatchHooks) -> ConversionDispatchHooks {
        .init(beforeSend: { kind in
            let token = hooks.beforeSend(kind)
            self.currentToken = token
            if let token { self.kinds[token] = kind }
            return token
        }, didReturn: hooks.didReturn, submissionCount: hooks.submissionCount, didLeaveDebt: hooks.didLeaveDebt)
    }

    private func receive(_ event: CGEvent, value: String) {
        if event.type == .keyDown {
            downCount += 1
            if insertion != .ignored, let range = Range(selection, in: text) {
                let start = selection.location
                let inserted = insertion == .partial ? String(value.prefix(2)) : value
                text.replaceSubrange(range, with: inserted)
                selection = insertion == .selected
                    ? NSRange(location: start, length: inserted.utf16.count)
                    : NSRange(location: start + inserted.utf16.count, length: 0)
            }
            onDown()
        } else {
            upCount += 1
        }
        if let token = currentToken, let kind = kinds[token], !unconfirmedKinds.contains(kind) {
            completed.insert(token)
        }
    }

    private func select(
        _ command: NativeSelectionCommand, before: () -> Bool, after: () -> Bool, hooks: ConversionDispatchHooks
    ) -> Bool {
        guard before() else { return false }
        let kind: ConversionSafetySubmissionKind = command == .collapse ? .restoreSelection : .selection
        guard let token = hooks.beforeSend(kind) else { return false }
        kinds[token] = kind
        commands.append(command)
        if selectionDelay > 0 || !pending.isEmpty {
            pending.append(.init(command: command, token: token, due: pending.last?.due ?? pauses + selectionDelay))
        } else {
            apply(command)
            if !unconfirmedKinds.contains(kind) { completed.insert(token) }
        }
        if case .select = command { onSelect() }
        hooks.didReturn(.init(submission: token, transport: .keyboard, status: nil))
        return after()
    }

    private func advance() {
        pauses += 1
        onPause()
        while let next = pending.first, next.due <= pauses {
            pending.removeFirst()
            apply(next.command)
            if let kind = kinds[next.token], !unconfirmedKinds.contains(kind) { completed.insert(next.token) }
        }
    }

    func applyDelayed() {
        for item in pending {
            apply(item.command)
            completed.insert(item.token)
        }
        pending.removeAll()
    }

    private func apply(_ command: NativeSelectionCommand) {
        switch command {
        case .select(let count):
            guard !ignoreSelection else { return }
            let prefix = (text as NSString).substring(to: selection.location)
            let units = String(prefix.suffix(partialSelection ? 2 : count)).utf16.count
            selection = NSRange(location: selection.location - units, length: units)
        case .collapse:
            guard !ignoreCollapse else { return }
            selection = NSRange(location: NSMaxRange(selection), length: 0)
        }
    }
}
