import AppKit

/// Собственная plain-text копия. Только обычное действие пользователя может скопировать выделение.
@MainActor
final class RecoveryPlainTextEditor: NSScrollView, NSTextViewDelegate {
    private let editor = RecoveryTextView()
    private let changed: ((String) -> Void)?

    init(text: String, editable: Bool, changed: ((String) -> Void)?, escape: @escaping () -> Void) {
        self.changed = changed
        super.init(frame: .zero)
        hasVerticalScroller = true
        borderType = .bezelBorder
        drawsBackground = true
        editor.string = text
        editor.isEditable = editable
        editor.isSelectable = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = editable
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.onEscape = escape
        editor.delegate = self
        documentView = editor
        setAccessibilityLabel(editable ? "Редактируемая копия фрагмента" : "Текстовый фрагмент события")
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        editor.setFrameSize(NSSize(width: contentSize.width, height: max(editor.frame.height, contentSize.height)))
    }

    func textDidChange(_ notification: Notification) {
        if editor.isEditable { changed?(editor.string) }
    }

    func flushEdits() {
        if editor.isEditable { changed?(editor.string) }
    }

    func focusForEditing() {
        guard editor.isEditable else { return }
        scrollToVisible(bounds)
        window?.makeFirstResponder(editor)
    }

    /// Удаляем видимый payload и undo-копии синхронно до отсоединения дерева AppKit/AX.
    func erasePresentation() {
        editor.delegate = nil
        editor.undoManager?.removeAllActions()
        editor.string = ""
        editor.onEscape = nil
    }
}

@MainActor
private final class RecoveryTextView: NSTextView {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
