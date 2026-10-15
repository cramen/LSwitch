import Foundation

/// Каждая стрелка должна добавить один grapheme к суффиксу, заканчивающемуся исходной кареткой.
struct KeyboardSelectionPlan {
    static let maximumCharacters = 256
    private static let bidirectional = try? NSRegularExpression(pattern: "[\\p{bc=R}\\p{bc=AL}\\p{Bidi_Control}]")

    let characterCount: Int
    let ownedRanges: [NSRange]

    init?(text: String, selection: NSRange, target: NSRange) {
        let source = text as NSString
        guard selection.length == 0, selection.location == source.length,
              target.location >= 0, target.length > 0, target.location <= source.length,
              target.length <= source.length - target.location, NSMaxRange(target) == selection.location,
              source.rangeOfComposedCharacterSequences(for: target) == target,
              let range = Range(target, in: text), let bidirectional = Self.bidirectional else { return nil }
        let span = text[range]
        let count = span.count
        guard count > 0, count <= Self.maximumCharacters,
              bidirectional.firstMatch(in: text, range: source.lineRange(for: target)) == nil else { return nil }
        var ranges = [selection]
        var start = selection.location
        for character in span.reversed() {
            start -= String(character).utf16.count
            ranges.append(NSRange(location: start, length: selection.location - start))
        }
        guard ranges.last == target else { return nil }
        self.characterCount = count
        self.ownedRanges = ranges
    }
}
