#if DEBUG
import AppKit

/// Наблюдает обычный NSTextView dispatch; не имитирует ввод прямым вызовом insertText.
@MainActor
final class RecoveryReceiverProbeView: NSTextView {
    var identify: (NSEvent) -> String? = { _ in nil }
    private(set) var received: [String] = []
    private(set) var foreignInputObserved = false
    private(set) var textChangeCount = 0
    private(set) var observationOverflow = false

    override func keyDown(with event: NSEvent) {
        observe(event)
        guard !foreignInputObserved, !observationOverflow else { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        observe(event)
        guard !foreignInputObserved, !observationOverflow else { return }
        super.keyUp(with: event)
    }

    override func didChangeText() {
        textChangeCount += 1
        super.didChangeText()
    }

    private func observe(_ event: NSEvent) {
        guard let label = identify(event) else {
            foreignInputObserved = true
            return
        }
        guard received.count < 8 else {
            observationOverflow = true
            return
        }
        received.append(label)
    }
}
#endif
