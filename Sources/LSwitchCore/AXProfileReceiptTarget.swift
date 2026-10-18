import ApplicationServices
import Foundation

/// Независимый anchor receipt. Не хранит Profile, Session, ledger, snapshot или input source.
@MainActor
final class AXProfileReceiptTarget {
    private let element: AXUIElement
    private let captured: AXProfileContext
    private let foreground: () -> Int32?
    private let focused: () -> AXUIElement?
    private let protected: (AXUIElement) -> Bool
    private let context: (AXUIElement) -> AXProfileContext?
    private let finalSelection: NSRange?

    init(element: AXUIElement, captured: AXProfileContext, environment: AXProfileEnvironment) {
        self.element = element
        self.captured = captured
        foreground = environment.foregroundProcessID
        focused = environment.focusedElement
        protected = environment.isProtected
        context = environment.context
        finalSelection = nil
    }

    private init(copying target: AXProfileReceiptTarget, finalSelection: NSRange) {
        element = target.element
        captured = target.captured
        foreground = target.foreground
        focused = target.focused
        protected = target.protected
        context = target.context
        self.finalSelection = finalSelection
    }

    func anchoring(finalSelection: NSRange) -> AXProfileReceiptTarget {
        .init(copying: self, finalSelection: finalSelection)
    }

    var hasFinalSelection: Bool {
        guard let finalSelection else { return false }
        return finalSelection.length == 0 && finalSelection.location >= 0
            && finalSelection.location <= AXProfileSnapshot.maximumUTF16Units
    }

    func matchesInitial(text: String, selection: NSRange, span: String) -> Bool {
        let units = text.utf16
        let length = span.utf16.count
        guard let finalSelection, selection == finalSelection, selection.length == 0,
              !span.isEmpty, selection.location >= length, units.count <= AXProfileSnapshot.maximumUTF16Units,
              selection.location <= units.count else { return false }
        let range = NSRange(location: selection.location - length, length: length)
        guard Range(range, in: text) != nil else { return false }
        let lower = units.index(units.startIndex, offsetBy: range.location)
        let upper = units.index(lower, offsetBy: length)
        return units[lower..<upper].elementsEqual(span.utf16)
    }

    /// Смена раскладки после конвертации ожидаема; identity документа проверяется заново.
    var isCurrent: Bool {
        guard !Task.isCancelled, foreground() == captured.process.processID, !protected(element),
              let current = focused(), CFEqual(current, element),
              let observed = context(element), matches(element: element, context: observed),
              !protected(element), let closing = focused(), CFEqual(closing, element),
              foreground() == captured.process.processID, !Task.isCancelled else { return false }
        return true
    }

    func matches(element: AXUIElement, context: AXProfileContext) -> Bool {
        CFEqual(self.element, element) && captured.matches(context)
    }
}
