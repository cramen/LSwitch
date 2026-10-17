#if DEBUG
import AppKit

/// Только фиксированный собственный fixture. Известный отрицательный пакет не фильтруется перед super.
@MainActor
final class RecoveryIsolationReceiverView: NSTextView {
    private let fixture = "ghbdtn "
    private var senderPID: Int32 = 0
    private var labels: [Int64: RecoveryIsolationLabel] = [:]
    private(set) var received: [String] = []
    private(set) var changeCount = 0
    private(set) var foreignInput = false
    private var legacyOverflow = false
    private var matrix = RecoveryIsolationMatrixState()
    private var overflowAbortScheduled = false
    var onAbort: ((String) -> Void)?

    var overflow: Bool { legacyOverflow || matrix.overflow }
    var matrixArmed: Bool { matrix.armed }
    var matrixLocal: [String: Int] { matrix.local }
    var matrixDispatch: [String: Int] { matrix.dispatched }
    private(set) var matrixShortcut: [String: Bool] = [:]
    private(set) var ordinaryWakeReleaseObserved = false

    func prepareFixture() {
        isRichText = false
        allowsUndo = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        string = fixture
        setSelectedRange(NSRange(location: fixture.utf16.count, length: 0))
        changeCount = 0
    }

    func configure(senderPID: Int32, markers: [RecoveryIsolationLabel: Int64]) -> Bool {
        guard labels.isEmpty, senderPID > 0,
              Set(markers.keys) == Set(RecoveryIsolationLabel.allCases),
              Set(markers.values).count == RecoveryIsolationLabel.allCases.count else { return false }
        self.senderPID = senderPID
        labels = Dictionary(uniqueKeysWithValues: markers.map { ($0.value, $0.key) })
        return true
    }

    func selectFixture() -> Bool {
        guard !matrixArmed, !labels.isEmpty, fixtureTextUnchanged else { return false }
        setSelectedRange(NSRange(location: 0, length: fixture.utf16.count))
        return fixtureSelectionUnchanged
    }

    func armEventMatrix() -> Bool {
        guard !labels.isEmpty, received.isEmpty, fixtureTextUnchanged,
              selectedRange() == NSRange(location: fixture.utf16.count, length: 0) else { return false }
        return matrix.arm()
    }

    var fixtureTextUnchanged: Bool {
        guard !foreignInput, !overflow else { return false }
        return string.utf16.elementsEqual(fixture.utf16)
    }

    var fixtureSelectionUnchanged: Bool {
        guard !foreignInput, !overflow else { return false }
        return selectedRange() == NSRange(location: 0, length: fixture.utf16.count)
    }

    var controlTextMatches: Bool {
        guard !foreignInput, !overflow else { return false }
        return string.utf16.elementsEqual("kept".utf16)
    }

    var controlSelectionMatches: Bool {
        guard !foreignInput, !overflow else { return false }
        return selectedRange() == NSRange(location: 4, length: 0)
    }

    var ordinaryContinuationTextMatches: Bool {
        guard !foreignInput, !overflow else { return false }
        return string.utf16.elementsEqual("keptx".utf16)
    }

    var ordinaryContinuationSelectionMatches: Bool {
        guard !foreignInput, !overflow else { return false }
        return selectedRange() == NSRange(location: 5, length: 0)
    }

    /// Строки читаются лишь у первого exact known-parent Cmd+A и сразу сводятся к булевым сравнениям.
    func permitsLocalEvent(_ event: NSEvent) -> Bool {
        if matrixArmed {
            guard let family = matrixFamily(event), permitsMatrixEvent(event, family: family) else {
                rejectForeignInput()
                return false
            }
            matrix.record(family, stage: .local)
            observeShortcutSemantics(event, family: family)
            scheduleMatrixOverflowAbort()
            return true
        }
        guard identify(event) != nil else {
            rejectForeignInput()
            return false
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard observe(event) else { return }
        super.keyDown(with: event)
        finishOverflowIfNeeded()
    }

    override func keyUp(with event: NSEvent) {
        guard observe(event) else { return }
        observeOrdinaryWakeRelease(event)
        super.keyUp(with: event)
        finishOverflowIfNeeded()
    }

    /// Факт обычного AppKit keyUp, а не одного label; payload события не читается.
    private func observeOrdinaryWakeRelease(_ event: NSEvent) {
        guard !matrixArmed, event.type == .keyUp, identify(event) == .challengeRelease,
              let native = event.cgEvent, native.type == .keyUp,
              native.getIntegerValueField(.keyboardEventKeycode) == 0,
              native.flags.subtracting(.maskNonCoalesced).isEmpty else { return }
        ordinaryWakeReleaseObserved = true
    }

    override func didChangeText() {
        changeCount += 1
        super.didChangeText()
    }

    private func identify(_ event: NSEvent) -> RecoveryIsolationLabel? {
        guard let native = event.cgEvent,
              native.getIntegerValueField(.eventSourceUnixProcessID) == Int64(senderPID) else { return nil }
        return labels[native.getIntegerValueField(.eventSourceUserData)]
    }

    private func observe(_ event: NSEvent) -> Bool {
        if matrixArmed { return observeMatrixDispatch(event) }
        guard let label = identify(event) else { rejectForeignInput(); return false }
        if received.count < RecoveryIsolationWire.maximumObservations {
            received.append(label.rawValue)
        } else {
            legacyOverflow = true
        }
        // Даже пакет сверх счётчика проходит super: overflow не должен скрывать утечку gate.
        return true
    }

    private func rejectForeignInput() {
        foreignInput = true
        onAbort?("unexpected_input")
    }

    private func finishOverflowIfNeeded() {
        if matrixArmed { scheduleMatrixOverflowAbort() } else if overflow { onAbort?("observation_overflow") }
    }

    private func observeMatrixDispatch(_ event: NSEvent) -> Bool {
        guard let family = matrixFamily(event), permitsMatrixEvent(event, family: family) else {
            rejectForeignInput()
            return false
        }
        matrix.record(family, stage: .dispatch)
        scheduleMatrixOverflowAbort()
        return true
    }

    private func observeShortcutSemantics(_ event: NSEvent, family: RecoveryIsolationMatrixFamily) {
        guard matrixShortcut.isEmpty, family == .keyDown else { return }
        // Вызывается только после permitsMatrixEvent: известный PID, marker, keyCode и flags.
        matrixShortcut = [
            "observed": true, "command": event.modifierFlags.contains(.command),
            "charactersA": event.characters == "a", "ignoringModifiersA": event.charactersIgnoringModifiers == "a"
        ]
    }

    private func permitsMatrixEvent(_ event: NSEvent, family: RecoveryIsolationMatrixFamily) -> Bool {
        switch family {
        case .keyDown, .keyUp, .flagsChanged:
            guard let label = identify(event), let native = event.cgEvent,
                  native.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
            return RecoveryIsolationMatrixKeyboard.permits(
                label: label, type: native.type,
                keyCode: native.getIntegerValueField(.keyboardEventKeycode), flags: native.flags
            )
        case .mouseDown, .mouseUp, .mouseDrag, .scroll:
            guard let window, event.window === window else { return false }
            // Координаты используются только для локальной границы fixture, не сохраняются и не выводятся.
            return visibleRect.contains(convert(event.locationInWindow, from: nil))
        }
    }

    private func matrixFamily(_ event: NSEvent) -> RecoveryIsolationMatrixFamily? {
        switch event.type {
        case .keyDown: return .keyDown
        case .keyUp: return .keyUp
        case .flagsChanged: return .flagsChanged
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .mouseDown
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return .mouseUp
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return .mouseDrag
        case .scrollWheel: return .scroll
        default: return nil
        }
    }

    private func scheduleMatrixOverflowAbort() {
        guard matrix.overflow, !overflowAbortScheduled else { return }
        overflowAbortScheduled = true
        // Известное текущее событие сначала возвращается AppKit; overflow не скрывает утечку gate.
        DispatchQueue.main.async { [weak self] in self?.onAbort?("observation_overflow") }
    }

    private func matrixDispatch(_ event: NSEvent, body: () -> Void) {
        if matrixArmed, !observeMatrixDispatch(event) { return }
        body()
        if matrixArmed { scheduleMatrixOverflowAbort() }
    }

    override func flagsChanged(with event: NSEvent) {
        matrixDispatch(event) { super.flagsChanged(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        matrixDispatch(event) { super.mouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        matrixDispatch(event) { super.mouseUp(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        matrixDispatch(event) { super.mouseDragged(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        matrixDispatch(event) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        matrixDispatch(event) { super.rightMouseUp(with: event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        matrixDispatch(event) { super.rightMouseDragged(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        matrixDispatch(event) { super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        matrixDispatch(event) { super.otherMouseUp(with: event) }
    }

    override func otherMouseDragged(with event: NSEvent) {
        matrixDispatch(event) { super.otherMouseDragged(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        matrixDispatch(event) { super.scrollWheel(with: event) }
    }
}
#endif
