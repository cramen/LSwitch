import AppKit
import LSwitchCore

/// Дерево payload создаётся только из явно раскрытой projection и удаляется синхронно при скрытии.
@MainActor
final class RecoveryWindowView: NSView {
    struct Actions {
        let reveal: () -> Void
        let edit: (Int) -> Void
        let delete: () -> Void
        let hide: () -> Void
        let save: (String, RecoveryWindowEditorToken) -> Void
    }

    private let actions: Actions
    private var payloadEditors: [RecoveryPlainTextEditor] = []
    private var draftEditor: RecoveryPlainTextEditor?
    private var metadataContainer: NSStackView?
    private var metadataRecordIdentifier: UUID?

    init(snapshot: RecoveryWindowSnapshot, draft: RecoveryWindowDraft?, actions: Actions) {
        self.actions = actions
        super.init(frame: .zero)
        let stack = verticalStack()
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])
        stack.addArrangedSubview(label("Сохранённый ввод", emphasis: true))
        if let metadata = snapshot.metadata {
            let section = verticalStack()
            metadataContainer = section
            metadataRecordIdentifier = metadata.recordIdentifier
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            _ = updateMetadata(metadata)
            if let notice = snapshot.notice { stack.addArrangedSubview(label(noticeText(notice))) }
            if snapshot.isVisible, !snapshot.isDeleted {
                addDisclosure(snapshot.projection, draft: draft, to: stack)
            }
        } else {
            stack.addArrangedSubview(label("Записи для восстановления пока нет."))
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        let delete = RecoveryActionButton(title: "Удалить…", action: actions.delete)
        delete.isEnabled = snapshot.metadata != nil && !snapshot.isDeleted
        buttons.addArrangedSubview(delete)
        let hide = RecoveryActionButton(title: "Скрыть", action: actions.hide)
        hide.keyEquivalent = "\u{1b}"
        buttons.addArrangedSubview(hide)
        stack.addArrangedSubview(buttons)
        fitLabels(in: stack)
    }

    required init?(coder: NSCoder) { nil }

    func flushEdits() { payloadEditors.forEach { $0.flushEdits() } }

    func focusDraft() { draftEditor?.focusForEditing() }

    /// Удаляются только labels metadata: payload subtree, NSTextView и first responder не затрагиваются.
    @discardableResult
    func updateMetadata(_ metadata: RecoveryWindowMetadata) -> Bool {
        guard metadata.recordIdentifier == metadataRecordIdentifier, let metadataContainer else { return false }
        for view in metadataContainer.arrangedSubviews {
            metadataContainer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        addMetadata(metadata, to: metadataContainer)
        fitLabels(in: metadataContainer)
        return true
    }

    func erasePayload() {
        payloadEditors.forEach { $0.erasePresentation() }
        payloadEditors.removeAll()
        draftEditor = nil
    }

    private func addMetadata(_ metadata: RecoveryWindowMetadata, to stack: NSStackView) {
        stack.addArrangedSubview(label("Приложение: \(metadata.applicationName)"))
        stack.addArrangedSubview(label(reasonText(metadata.reason)))
        let protection = label(protectionText(metadata.protection))
        protection.textColor = metadata.protection == .verifiedBlocking ? .labelColor : .systemOrange
        stack.addArrangedSubview(protection)
        stack.addArrangedSubview(label(
            "Сохранено событий: \(metadata.counts.events). Объём текстовых данных: \(metadata.counts.utf16Bytes) байт."
        ))
        stack.addArrangedSubview(label("Данные находятся только в памяти и не отправляются автоматически."))
        if metadata.ordinaryDelivery?.possiblyAlreadyDelivered == true {
            let warning = label(
                "Часть сохранённого ввода могла уже попасть в приложение. "
                    + "Перед копированием проверьте исходный текст."
            )
            warning.textColor = .systemOrange
            stack.addArrangedSubview(warning)
        }
    }

    private func addDisclosure(
        _ projection: RecoveryProjection?, draft: RecoveryWindowDraft?, to stack: NSStackView
    ) {
        guard let projection else {
            stack.addArrangedSubview(label("Содержимое скрыто. Закрытие окна сохранит запись и ваши черновики."))
            stack.addArrangedSubview(RecoveryActionButton(
                title: "Показать сохранённые события", action: actions.reveal
            ))
            return
        }
        guard projection.failure == nil else {
            stack.addArrangedSubview(label("Предел просмотра превышен. Исходная запись сохранена."))
            return
        }
        stack.addArrangedSubview(label("Здесь данные отдельных событий. Итоговый текст поля не вычислялся."))
        let document = verticalStack()
        for entry in projection.entries { addEntry(entry, to: document) }
        if projection.entries.isEmpty { document.addArrangedSubview(label("В сохранённой очереди нет событий.")) }
        if let draft { addDraft(draft, to: document) }
        fitLabels(in: document)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func addEntry(_ entry: RecoveryProjectionEntry, to stack: NSStackView) {
        let prefix = "Событие \(entry.ordinal + 1)"
        switch entry.content {
        case .unicodeFragment(let fragment):
            stack.addArrangedSubview(label("\(prefix) · Текстовый фрагмент события", emphasis: true))
            addEditor(text: fragment.text, changed: nil, height: 72, to: stack)
            let ordinal = entry.ordinal
            stack.addArrangedSubview(RecoveryActionButton(title: "Редактировать копию этого фрагмента") { [weak self] in
                self?.actions.edit(ordinal)
            })
        case .nonText(let event):
            stack.addArrangedSubview(label("\(prefix) · \(eventText(event)). Команда не исполнялась."))
        case .unresolved(let issue):
            stack.addArrangedSubview(label("\(prefix) · \(issueText(issue))"))
        }
    }

    private func addDraft(_ draft: RecoveryWindowDraft, to stack: NSStackView) {
        stack.addArrangedSubview(label("Редактируемая копия фрагмента", emphasis: true))
        stack.addArrangedSubview(label("Команды не применялись. Черновик хранится в памяти; копирование — вручную."))
        let token = draft.token
        addEditor(text: draft.text, changed: { [weak self] in self?.actions.save($0, token) }, height: 150, to: stack)
    }

    private func addEditor(text: String, changed: ((String) -> Void)?, height: CGFloat, to stack: NSStackView) {
        let editor = RecoveryPlainTextEditor(
            text: text, editable: changed != nil, changed: changed, escape: actions.hide
        )
        payloadEditors.append(editor)
        if changed != nil { draftEditor = editor }
        stack.addArrangedSubview(editor)
        editor.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        editor.heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    private func verticalStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 10
        return stack
    }

    private func fitLabels(in stack: NSStackView) {
        for field in stack.arrangedSubviews where field is NSTextField {
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func label(_ text: String, emphasis: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: emphasis ? 14 : 13, weight: emphasis ? .semibold : .regular)
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        return field
    }

    private func reasonText(_ reason: RecoveryWindowReason) -> String {
        switch reason {
        case .cleanupUnconfirmed: return "Не удалось подтвердить безопасное восстановление поля ввода."
        case .admissionStopped: return "Обработка ввода остановлена; уже принятые события сохранены."
        case .gateLost: return "Защита исходного приложения стала недоступна."
        case .interceptionStopped: return "Перехват ввода остановлен; сохранённая запись остаётся доступной."
        case .ordinaryDeliveryUnconfirmed: return "Не удалось подтвердить завершение доставки сохранённого ввода."
        }
    }

    private func protectionText(_ protection: RecoveryWindowProtection) -> String {
        switch protection {
        case .verifiedBlocking:
            return "Новые нажатия в исходное приложение блокируются и не сохраняются. Их потребуется повторить."
        case .unverified:
            return "Блокировка нового ввода в исходное приложение не подтверждена."
        case .unavailable:
            return "Защита недоступна. LSwitch не контролирует дальнейший ввод в исходное приложение."
        case .off:
            return "Защита исходного приложения остановлена. Новый ввод не блокируется; данные остаются в памяти."
        }
    }

    private func noticeText(_ notice: RecoveryWindowNotice) -> String {
        switch notice {
        case .revealUnavailable: return "Не удалось раскрыть эту запись. Содержимое не показано."
        case .deletionRefused: return "Удаление не подтверждено. Запись и ваши черновики сохранены."
        case .deleted: return "Запись и черновики удалены. Состояние исходного поля по-прежнему не подтверждено."
        }
    }

    private func eventText(_ event: RecoveryNonTextEvent) -> String {
        switch event {
        case .keyRelease: return "Отпускание клавиши"
        case .modifierChange: return "Изменение модификатора"
        case .modifiedKey: return "Клавиша с командным модификатором"
        case .editingKey(let key): return editingKeyText(key)
        case .mouse(let button, let phase): return "Мышь: \(mouseButtonText(button)), \(mousePhaseText(phase))"
        }
    }

    private func mouseButtonText(_ button: RecoveryMouseButton) -> String {
        switch button {
        case .left: return "левая кнопка"
        case .right: return "правая кнопка"
        case .other: return "дополнительная кнопка"
        }
    }

    private func mousePhaseText(_ phase: RecoveryMousePhase) -> String {
        switch phase {
        case .down: return "нажатие"
        case .release: return "отпускание"
        case .drag: return "перетаскивание"
        }
    }

    private func editingKeyText(_ key: RecoveryEditingKey) -> String {
        switch key {
        case .backspace: return "Backspace"
        case .forwardDelete: return "Delete"
        case .enter: return "Enter"
        case .tab: return "Tab"
        case .escape: return "Escape"
        case .navigation: return "Клавиша навигации"
        case .function: return "Функциональная клавиша"
        }
    }

    private func issueText(_ issue: RecoveryProjectionIssue) -> String {
        switch issue {
        case .missingUnicodePayload: return "Нет подтверждённого текстового фрагмента."
        case .invalidUTF16: return "Повреждённые текстовые данные; текст не восстановлен."
        case .unicodeReadInconsistent: return "Данные события не удалось прочитать согласованно."
        case .controlUnicodePayload: return "Управляющие данные; итоговый текст не вычислялся."
        case .modifierDependentInput: return "Ввод зависит от модификатора; текст не угадывается."
        case .unsupportedModifiers: return "Неизвестные модификаторы; текст не угадывается."
        case .unsupportedEvent: return "Тип события не поддерживает текстовое представление."
        }
    }
}

@MainActor
private final class RecoveryActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(invoke)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func invoke() { handler() }
}
