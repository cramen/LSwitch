import Foundation

/// Чистый план одной записи. Все внешние позиции представлены в UTF-16.
struct AXReplacementPlan {
    let text: String
    let selection: NSRange
    let range: NSRange
    let receipt: ConversionReceipt
    let wasSelection: Bool
    let resultingText: String

    var replacement: String { receipt.converted + receipt.trailingText }

    var finalSelection: NSRange {
        NSRange(location: range.location + replacement.utf16.count, length: 0)
    }

    /// После неверной записи узнаём оставленное движком выделение по позиции и содержимому.
    func cleanupCaret(in currentText: String, selection: NSRange) -> NSRange? {
        guard selection.length > 0, let originalRange = Range(range, in: text),
              let selectedRange = Range(selection, in: currentText) else { return nil }
        let insertionPoint = originalRange.upperBound
        let insertedText = text.replacingCharacters(in: insertionPoint..<insertionPoint, with: replacement)
        guard currentText == resultingText || currentText == insertedText else { return nil }
        let selected = String(currentText[selectedRange])
        let originalSpan = receipt.original + receipt.trailingText
        let originalSelection = selection == range && selected == originalSpan
        let replacementSelection = selected == replacement && (
            selection.location == range.location || selection.location == NSMaxRange(range)
        )
        guard originalSelection || replacementSelection else { return nil }
        return NSRange(location: NSMaxRange(selection), length: 0)
    }

    init?(
        text: String,
        selection: NSRange,
        request: ConversionRequest,
        transform: (String) -> String
    ) {
        guard let selectedRange = Range(selection, in: text) else { return nil }
        let target: Range<String.Index>
        let original: String
        let tail: String
        let wasSelection = request.useSelection && selection.length > 0
        if wasSelection {
            target = selectedRange
            original = String(text[target])
            tail = ""
        } else {
            guard selection.length == 0 else { return nil }
            let cursor = selectedRange.lowerBound
            if let expectedSpan = request.expectedSpan {
                let length = expectedSpan.utf16.count
                guard selection.location >= length,
                      let expectedRange = Range(
                        NSRange(location: selection.location - length, length: length), in: text
                      ), let parts = request.matchingParts(in: String(text[expectedRange])) else { return nil }
                target = expectedRange
                original = parts.word
                tail = parts.tail
            } else {
                guard let word = WordBoundary.lastWord(in: text, beforeCursor: cursor) else { return nil }
                target = word.lowerBound..<cursor
                original = String(text[word])
                tail = String(text[word.upperBound..<cursor])
            }
        }
        guard !original.isEmpty else { return nil }
        let converted = transform(original)
        self.text = text
        self.selection = selection
        self.range = NSRange(target, in: text)
        self.receipt = ConversionReceipt(original: original, converted: converted, trailingText: tail)
        self.wasSelection = wasSelection
        self.resultingText = text.replacingCharacters(in: target, with: converted + tail)
    }
}
