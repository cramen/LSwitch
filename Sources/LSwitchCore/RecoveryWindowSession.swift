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
            counts: .init(events: 0, utf16Bytes: 0), reason: metadata.reason, protection: metadata.protection
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
        return isVisible && record?.metadata.recordIdentifier == metadata.recordIdentifier
    }

    public func hide() {
        let previous = record
        isVisible = false
        invalidateDisclosure()
        cancelPendingDeletion()
        if let previous { previous.actions.didHide(previous.metadata.recordIdentifier) }
    }

    /// Каждый вызов означает новое явное действие; чтение происходит только через bound адаптер.
    @discardableResult
    public func reveal() -> Bool {
        guard isVisible, let record, !record.isDeleted, pendingDeletion == nil,
              !isRequestingDeletion, !isResolvingDeletion else { return false }
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
              !isRequestingDeletion, !isResolvingDeletion else { return nil }
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
              !isResolvingDeletion, visibleFragment(ordinal: token.ordinal) != nil else { return false }
        record.drafts[token.ordinal] = text
        return true
    }

    public func requestDeletion() -> RecoveryWindowDeletionIntent? {
        guard isVisible, let record, !record.isDeleted, pendingDeletion == nil,
              !isRequestingDeletion, !isResolvingDeletion else { return nil }
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
