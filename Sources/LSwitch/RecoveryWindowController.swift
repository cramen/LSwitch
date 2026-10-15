import AppKit
import LSwitchCore

/// Пока не подключён к runtime. Видимость/активация окна никогда не выдаёт разрешение replay.
@MainActor
final class RecoveryWindowController: NSObject, NSWindowDelegate {
    private let session: RecoveryWindowSession
    private var window: NSWindow?
    private var content: RecoveryWindowView?
    private var deletionSheet: NSAlert?
    private var deletionIntent: RecoveryWindowDeletionIntent?

    init(session: RecoveryWindowSession? = nil) {
        self.session = session ?? RecoveryWindowSession()
        super.init()
    }

    /// Подготавливает только собственное скрытое окно; системный gate готовностью окна не подтверждается.
    func prepare() {
        guard window == nil else { return }
        let prepared = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        prepared.title = "Восстановление ввода — LSwitch"
        prepared.isReleasedWhenClosed = false
        prepared.minSize = NSSize(width: 540, height: 450)
        prepared.delegate = self
        prepared.center()
        window = prepared
        render()
    }

    func show(_ metadata: RecoveryWindowMetadata, actions: RecoveryWindowActions) {
        content?.flushEdits()
        let current = session.snapshot
        if let previous = current.metadata, !current.isDeleted,
           previous.recordIdentifier != metadata.recordIdentifier { return }
        content?.erasePayload()
        guard session.show(metadata, actions: actions) else { return }
        prepare()
        dismissSheet()
        render()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        content?.flushEdits()
        window?.makeFirstResponder(nil)
        content?.erasePayload()
        session.hide()
        dismissSheet()
        render()
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    private func render(draft: RecoveryWindowDraft? = nil) {
        content?.erasePayload()
        let view = RecoveryWindowView(
            snapshot: session.snapshot, draft: draft,
            actions: .init(reveal: { [weak self] in self?.reveal() }, edit: { [weak self] ordinal in
                self?.editFragment(ordinal)
            }, delete: { [weak self] in self?.requestDeletion() }, hide: { [weak self] in self?.hide() },
            save: { [weak self] text, token in _ = self?.session.saveDraft(text, token: token) })
        )
        content = view
        window?.contentView = view
        if draft != nil { view.focusDraft() }
    }

    private func reveal() {
        content?.flushEdits()
        session.reveal()
        render()
    }

    private func editFragment(_ ordinal: Int) {
        content?.flushEdits()
        guard let draft = session.editFragment(ordinal: ordinal) else { return }
        render(draft: draft)
    }

    private func requestDeletion() {
        content?.flushEdits()
        guard let window, deletionSheet == nil, let intent = session.requestDeletion() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Удалить сохранённый ввод и черновики?"
        alert.informativeText = "Данные будут удалены из памяти. Это не исправит выделение в исходном приложении."
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Удалить")
        deletionSheet = alert
        deletionIntent = intent
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.resolveDeletion(intent, confirm: response == .alertSecondButtonReturn)
        }
    }

    private func resolveDeletion(_ intent: RecoveryWindowDeletionIntent, confirm: Bool) {
        if confirm, deletionIntent == intent { content?.erasePayload() }
        let result = session.resolveDeletion(intent, confirm: confirm)
        if deletionIntent == intent {
            deletionSheet = nil
            deletionIntent = nil
        }
        if result == .deleted || result == .refused { render() }
    }

    private func dismissSheet() {
        if let sheet = deletionSheet?.window { window?.endSheet(sheet, returnCode: .abort) }
        deletionSheet = nil
        deletionIntent = nil
    }
}
