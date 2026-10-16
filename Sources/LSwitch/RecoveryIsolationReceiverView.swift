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
    private(set) var overflow = false
    var onAbort: ((String) -> Void)?

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
        guard !labels.isEmpty, fixtureTextUnchanged else { return false }
        setSelectedRange(NSRange(location: 0, length: fixture.utf16.count))
        return fixtureSelectionUnchanged
    }

    var fixtureTextUnchanged: Bool {
        guard !foreignInput, !overflow else { return false }
        return string.utf16.elementsEqual(fixture.utf16)
    }

    var fixtureSelectionUnchanged: Bool {
        guard !foreignInput, !overflow else { return false }
        return selectedRange() == NSRange(location: 0, length: fixture.utf16.count)
    }

    /// Local monitor не читает characters/Unicode. PID и marker — граница опыта, не аутентификация.
    func permitsLocalEvent(_ event: NSEvent) -> Bool {
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
        super.keyUp(with: event)
        finishOverflowIfNeeded()
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
        guard let label = identify(event) else { rejectForeignInput(); return false }
        if received.count < RecoveryIsolationWire.maximumObservations {
            received.append(label.rawValue)
        } else {
            overflow = true
        }
        // Даже пакет сверх счётчика проходит super: overflow не должен скрывать утечку gate.
        return true
    }

    private func rejectForeignInput() {
        foreignInput = true
        onAbort?("unexpected_input")
    }

    private func finishOverflowIfNeeded() {
        if overflow { onAbort?("observation_overflow") }
    }
}
#endif
