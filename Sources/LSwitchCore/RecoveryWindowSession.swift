import Foundation

/// Чистое состояние одного окна; закрытие скрывает payload, но сохраняет пользовательские RAM-копии.
@MainActor
public final class RecoveryWindowSession {
    private final class Record {
        var metadata: RecoveryWindowMetadata
        var actions: RecoveryWindowActions
        var drafts: [Int: String] = [:]
        var isDeleted = false

        init(metadata: RecoveryWindowMetadata, actions: RecoveryWindowActions) {
            self.metadata = metadata
            self.actions = actions
        }
    }

    private struct PendingDeletion {
        let intent: RecoveryWindowDeletionIntent
        let request: RecoveryWindowDeletionRequest
    }

    private struct PendingQuit {
        let intent: RecoveryWindowQuitIntent
        let request: RecoveryQuitConfirmation
    }

    private let identifier = UUID()
    private var record: Record?
    private var revision = UUID()
    private var isVisible = false
    private var projection: RecoveryProjection?
    private var notice: RecoveryWindowNotice?
    private var activeEditor: RecoveryWindowEditorToken?
    private var pendingDeletion: PendingDeletion?
    private var isRequestingDeletion = false
    private var isResolvingDeletion = false
    private var pendingQuit: PendingQuit?
    private var isRequestingQuit = false
    private var isResolvingQuit = false

    public init() {}

    public var snapshot: RecoveryWindowSnapshot {
        .init(metadata: displayedMetadata, isVisible: isVisible, isDeleted: record?.isDeleted ?? false,
              projection: isVisible ? projection : nil, notice: notice)
    }

    private var displayedMetadata: RecoveryWindowMetadata? {
        guard let record else { return nil }
        let metadata = record.metadata
        guard record.isDeleted else { return metadata }
        return .init(
            recordIdentifier: metadata.recordIdentifier, applicationName: metadata.applicationName,
            counts: .init(events: 0, utf16Bytes: 0), reason: metadata.reason, protection: metadata.protection,
            ordinaryDelivery: metadata.ordinaryDelivery
        )
    }

    /// Другая запись не вытесняет прежние черновики. Новая запись допустима после явного удаления.
    @discardableResult
    public func show(_ metadata: RecoveryWindowMetadata, actions: RecoveryWindowActions) -> Bool {
        if let record, !record.isDeleted, record.metadata.recordIdentifier != metadata.recordIdentifier {
            return false
        }
        if record == nil || record?.metadata.recordIdentifier != metadata.recordIdentifier {
            record = Record(metadata: metadata, actions: actions)
        }
        record?.metadata = metadata
        record?.actions = actions
        invalidateDisclosure()
        isVisible = true
        notice = record?.isDeleted == true ? .deleted : nil
        cancelPendingDeletion()
        cancelPendingQuit()
        return isVisible && record?.metadata.recordIdentifier == metadata.recordIdentifier
    }

    public func hide() {
        let previous = record
        isVisible = false
        invalidateDisclosure()
        cancelPendingDeletion()
        cancelPendingQuit()
        if let previous { previous.actions.didHide(previous.metadata.recordIdentifier) }
    }

    /// Каждый вызов означает новое явное действие; чтение происходит только через bound адаптер.
    @discardableResult
    public func reveal() -> Bool {
        guard isVisible, let record, !record.isDeleted, pendingDeletion == nil,
              !isRequestingDeletion, !isResolvingDeletion, !quitIsBusy else { return false }
        invalidateDisclosure()
        let expected = revision
        let result = record.actions.reveal(record.metadata.recordIdentifier)
        guard self.record === record, isVisible, !record.isDeleted, revision == expected else { return false }
        guard let result, result.recordIdentifier == record.metadata.recordIdentifier else {
            notice = .revealUnavailable
            return false
        }
        projection = result
        notice = nil
        return true
    }

    /// Копия создаётся лишь отдельным действием для конкретного Unicode-фрагмента.
    public func editFragment(ordinal: Int) -> RecoveryWindowDraft? {
        guard let record, let fragment = visibleFragment(ordinal: ordinal), pendingDeletion == nil,
              !isRequestingDeletion, !isResolvingDeletion, !quitIsBusy else { return nil }
        if record.drafts[ordinal] == nil { record.drafts[ordinal] = fragment.text }
        let token = RecoveryWindowEditorToken(
            session: identifier, record: record.metadata.recordIdentifier, revision: revision, ordinal: ordinal
        )
        activeEditor = token
        return .init(token: token, text: record.drafts[ordinal] ?? fragment.text)
    }

    @discardableResult
    public func saveDraft(_ text: String, token: RecoveryWindowEditorToken) -> Bool {
        guard token == activeEditor, token.session == identifier, token.revision == revision,
              let record, token.record == record.metadata.recordIdentifier,
              !isResolvingDeletion, !quitIsBusy, visibleFragment(ordinal: token.ordinal) != nil else { return false }
        record.drafts[token.ordinal] = text
        return true
    }

    public func requestDeletion() -> RecoveryWindowDeletionIntent? {
        guard isVisible, let record, !record.isDeleted, pendingDeletion == nil,
              !isRequestingDeletion, !isResolvingDeletion, !quitIsBusy else { return nil }
        isRequestingDeletion = true
        defer { isRequestingDeletion = false }
        let expected = revision
        guard let request = record.actions.requestDeletion(record.metadata.recordIdentifier) else { return nil }
        guard self.record === record, isVisible, !record.isDeleted, revision == expected,
              request.recordIdentifier == record.metadata.recordIdentifier else {
            request.cancel()
            return nil
        }
        let intent = RecoveryWindowDeletionIntent(session: identifier, record: record.metadata.recordIdentifier)
        pendingDeletion = PendingDeletion(intent: intent, request: request)
        return intent
    }

    @discardableResult
    public func resolveDeletion(_ intent: RecoveryWindowDeletionIntent, confirm: Bool) -> RecoveryWindowDeletionResult {
        guard let pending = pendingDeletion, pending.intent == intent, isVisible,
              let record, !record.isDeleted, !isResolvingDeletion,
              record.metadata.recordIdentifier == intent.record else { return .stale }
        pendingDeletion = nil
        isResolvingDeletion = true
        defer { isResolvingDeletion = false }
        guard confirm else {
            pending.request.cancel()
            return .cancelled
        }
        // Confirm-путь уже убрал редактор из AppKit; поздний delegate не изменяет сохранённую копию.
        activeEditor = nil
        let expected = revision
        guard pending.request.confirm() else {
            if self.record === record, revision == expected { notice = .deletionRefused }
            return .refused
        }
        record.drafts.removeAll()
        record.isDeleted = true
        if self.record === record {
            invalidateDisclosure()
            notice = .deleted
        }
        return .deleted
    }

    private func visibleFragment(ordinal: Int) -> RecoveryUnicodeFragment? {
        guard isVisible, let record, !record.isDeleted, let projection, projection.failure == nil,
              projection.recordIdentifier == record.metadata.recordIdentifier,
              let entry = projection.entries.first(where: { $0.ordinal == ordinal }),
              case .unicodeFragment(let fragment) = entry.content else { return nil }
        return fragment
    }

    private func invalidateDisclosure() {
        revision = UUID()
        projection = nil
        activeEditor = nil
    }

    private func cancelPendingDeletion() {
        let pending = pendingDeletion
        pendingDeletion = nil
        pending?.request.cancel()
    }
}

extension RecoveryWindowSession {
    /// Quit допускается и из скрытого окна. Он не раскрывает payload и не уничтожает черновики при отмене.
    public func requestQuit(actions: RecoveryQuitActions) -> RecoveryWindowQuitRequest {
        if let pendingQuit { return .confirmationRequired(pendingQuit.intent) }
        guard !isRequestingQuit, !isResolvingQuit, !isRequestingDeletion, !isResolvingDeletion else {
            return .handoverRequired
        }
        isRequestingQuit = true
        defer { isRequestingQuit = false }
        cancelPendingDeletion()
        invalidateDisclosure()
        let expected = revision
        let current = record
        let request = actions.request()
        guard revision == expected, record === current else {
            if case .confirmationRequired(let confirmation) = request { confirmation.cancel() }
            return .handoverRequired
        }
        switch request {
        case .allowed:
            return record == nil || record?.isDeleted == true ? .allowed : .handoverRequired
        case .handoverRequired:
            return .handoverRequired
        case .confirmationRequired(let confirmation):
            guard let record, confirmation.recordIdentifier == record.metadata.recordIdentifier else {
                confirmation.cancel()
                return .handoverRequired
            }
            let intent = RecoveryWindowQuitIntent(session: identifier, record: confirmation.recordIdentifier)
            pendingQuit = .init(intent: intent, request: confirmation)
            return .confirmationRequired(intent)
        }
    }

    @discardableResult
    public func resolveQuit(_ intent: RecoveryWindowQuitIntent, confirm: Bool) -> RecoveryWindowQuitResolution {
        guard let pending = pendingQuit, pending.intent == intent, let record,
              record.metadata.recordIdentifier == intent.record, !isResolvingQuit else { return .stale }
        pendingQuit = nil
        isResolvingQuit = true
        defer { isResolvingQuit = false }
        guard confirm else { pending.request.cancel(); return .cancelled }
        guard pending.request.confirm() else {
            if self.record === record { notice = .deletionRefused }
            return .refused
        }
        // Только подтверждённая запись: reentrant show не даёт удалить черновики другой записи.
        record.drafts.removeAll()
        record.isDeleted = true
        if self.record === record {
            invalidateDisclosure()
            notice = .deleted
        }
        return .quitAllowed
    }

    private var quitIsBusy: Bool { pendingQuit != nil || isRequestingQuit || isResolvingQuit }

    private func cancelPendingQuit() {
        let pending = pendingQuit
        pendingQuit = nil
        pending?.request.cancel()
    }
}
