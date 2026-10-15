import Foundation

extension UnicodeEnvironment {
    typealias TextReadPermission = @MainActor () -> Bool

    /// Raw getters доступны только проверяемой границе в этом файле.
    struct Context {
        fileprivate let processID: pid_t
        fileprivate let isCurrent: @MainActor @Sendable () -> Bool
        fileprivate let rawSnapshot: @MainActor (TextReadPermission) -> UnicodeTextSnapshot?
        fileprivate let automaticContext: @MainActor @Sendable () -> AutomaticTextContext
        fileprivate let rawDocumentIdentity: @MainActor @Sendable () -> String?

        init(
            processID: pid_t, isCurrent: @escaping @MainActor @Sendable () -> Bool,
            rawSnapshot: @escaping @MainActor (TextReadPermission) -> UnicodeTextSnapshot?,
            automaticContext: @escaping @MainActor @Sendable () -> AutomaticTextContext,
            rawDocumentIdentity: @escaping @MainActor @Sendable () -> String?
        ) {
            self.processID = processID
            self.isCurrent = isCurrent
            self.rawSnapshot = rawSnapshot
            self.automaticContext = automaticContext
            self.rawDocumentIdentity = rawDocumentIdentity
        }
    }
}

/// Разрешение проверяется заново вокруг каждого чтения; через await хранится только эталон identity/source.
@MainActor
struct UnicodeReadBoundary {
    private let context: UnicodeEnvironment.Context
    private let source: UnicodeInputSource
    private let activeSource: () -> UnicodeInputSource?
    let request: ConversionRequest
    let automatic: AutomaticTextContext
    let targetCheck: ConversionReceipt.TargetCheck

    var processID: pid_t { context.processID }

    var isValid: Bool {
        !Task.isCancelled && request.isValid() && activeSource() == source && !Task.isCancelled
    }

    var canCleanup: Bool { request.canCleanup() }

    static func capture(
        context: UnicodeEnvironment.Context, request: ConversionRequest,
        source: UnicodeInputSource, activeSource: @escaping () -> UnicodeInputSource?
    ) -> UnicodeReadBoundary? {
        guard !Task.isCancelled, request.isValid() else { return nil }
        guard let identity = checkedIdentity(context) else {
            request.diagnostics?.reject(.unicodeSnapshotUnverified)
            return nil
        }
        guard !Task.isCancelled, request.isValid(), activeSource() == source else {
            request.diagnostics?.reject(.requestInvalid)
            return nil
        }
        let check: ConversionReceipt.TargetCheck = { checkedIdentity(context) == identity }
        let automatic = request.isAutomatic ? context.automaticContext() : .prose
        let scoped = scope(request, target: check).checkingDocumentContext(automatic, read: context.automaticContext)
        return UnicodeReadBoundary(context: context, source: source, activeSource: activeSource,
                                   request: scoped, automatic: automatic, targetCheck: check)
    }

    func read(cleanup: Bool = false) -> UnicodeTextSnapshot? {
        guard cleanup ? canCleanup : isValid else { return nil }
        let snapshot = context.rawSnapshot {
            (cleanup || !Task.isCancelled) && self.context.isCurrent()
        }
        guard cleanup ? canCleanup : isValid else { return nil }
        guard let snapshot, snapshot.isComplete else {
            request.diagnostics?.reject(.unicodeSnapshotUnverified)
            return nil
        }
        return snapshot
    }

    private static func checkedIdentity(_ context: UnicodeEnvironment.Context) -> String? {
        guard context.isCurrent() else { return nil }
        let identity = context.rawDocumentIdentity()
        guard context.isCurrent() else { return nil }
        return identity
    }

    /// Проверка lease/revision после raw identity ловит инвалидацию внутри этого IPC.
    private static func scope(_ original: ConversionRequest, target: @escaping ConversionReceipt.TargetCheck)
        -> ConversionRequest {
        ConversionRequest(
            expectedWord: original.expectedWord, trailingText: original.trailingText,
            replacement: original.replacement, sourceLayout: original.sourceLayout,
            useSelection: original.useSelection, diagnostics: original.diagnostics,
            safetyLedger: original.safetyLedger,
            beginMutation: original.beginMutation,
            canCleanup: { target() && original.canCleanup() },
            isValid: {
                guard target() else { return original.diagnostics?.reject(.documentChanged) ?? false }
                return original.isValid()
            }
        )
    }
}
