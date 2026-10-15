import Foundation

/// Ограниченный лексический проход от начала полного снимка до конца слова.
struct SourceTextLexer {
    typealias Region = AutomaticTextPolicy.Region

    private enum State {
        case code, lineComment, blockComment(Int), quoted(UInt16, Bool)
    }

    let units: [UInt16]
    let language: SourceLanguage

    func region(in range: NSRange) -> Region {
        if language == .cLike, (0..<NSMaxRange(range)).contains(where: { ambiguousPreprocessing(at: $0) }) {
            return .unknown
        }
        var state = State.code
        var position = 0
        var regions = [Region](repeating: .code, count: NSMaxRange(range))
        while position < regions.count {
            guard let step = advance(at: position, state: state) else { return .unknown }
            let end = min(position + step.length, regions.count)
            for index in position..<end { regions[index] = step.region }
            state = step.state
            position = end
        }
        let selected = regions[range.location..<NSMaxRange(range)]
        guard let first = selected.first, selected.allSatisfy({ $0 == first }) else { return .unknown }
        return first
    }

    private typealias Step = (length: Int, region: Region, state: State)

    private func advance(at position: Int, state: State) -> Step? {
        switch state {
        case .code: return advanceCode(at: position)
        case .lineComment:
            return (1, .comment, isNewline(units[position]) ? .code : state)
        case .blockComment(let depth): return advanceComment(at: position, depth: depth)
        case .quoted(let quote, let triple): return advanceString(at: position, quote: quote, triple: triple)
        }
    }

    private func advanceCode(at position: Int) -> Step? {
        let unit = units[position]
        if language == .python, unit == 35 { return (1, .code, .lineComment) }
        if language != .python, matches([47, 47], at: position) { return (2, .code, .lineComment) }
        if language != .python, matches([47, 42], at: position) { return (2, .code, .blockComment(1)) }
        // JS/Swift допускают regex literal; без полноценного parser '/' неоднозначен.
        if unit == 47, language == .javascript || language == .swift { return nil }
        if unit == 96, language == .javascript { return nil }
        if unit == 35, language == .swift,
           next(after: position) == 34 || next(after: position) == 47 { return nil }
        guard unit == 34 || unit == 39 else { return (1, .code, .code) }
        if language == .swift, unit == 39 { return nil }
        guard !hasUnsupportedPrefix(at: position) else { return nil }
        let triple = matches([unit, unit, unit], at: position)
        if triple, language != .python && language != .swift { return nil }
        return (triple ? 3 : 1, .code, .quoted(unit, triple))
    }

    private func advanceComment(at position: Int, depth: Int) -> Step? {
        if matches([47, 42], at: position) {
            guard language == .swift else { return nil }
            return (2, .code, .blockComment(depth + 1))
        }
        if matches([42, 47], at: position) {
            return (2, .code, depth == 1 ? .code : .blockComment(depth - 1))
        }
        return (1, .comment, .blockComment(depth))
    }

    private func advanceString(at position: Int, quote: UInt16, triple: Bool) -> Step? {
        let unit = units[position]
        let state = State.quoted(quote, triple)
        if unit == 92 {
            guard let following = next(after: position) else { return nil }
            if language == .swift, following == 40 { return nil }
            return (2, .code, state)
        }
        if language == .cLike, unit == 36 { return nil }
        if !triple, isNewline(unit) { return nil }
        if triple, matches([quote, quote, quote], at: position) { return (3, .code, .code) }
        if !triple, unit == quote { return (1, .code, .code) }
        let region: Region = language == .cLike && quote == 39 ? .code : .string
        return (1, region, state)
    }

    private func hasUnsupportedPrefix(at position: Int) -> Bool {
        guard position > 0 else { return false }
        let previous = units[position - 1]
        if language == .cLike, previous == 64 || previous == 36 || previous == 82 { return true }
        guard language == .python else { return false }
        // f/r/b/u и их сочетания меняют грамматику литерала; не угадываем её.
        var start = position
        while start > 0, isASCIILetter(units[start - 1]) { start -= 1 }
        return start < position
    }

    private func matches(_ expected: [UInt16], at position: Int) -> Bool {
        guard position + expected.count <= units.count else { return false }
        return units[position..<(position + expected.count)].elementsEqual(expected)
    }

    private func next(after position: Int) -> UInt16? {
        position + 1 < units.count ? units[position + 1] : nil
    }

    private func ambiguousPreprocessing(at position: Int) -> Bool {
        if matches([63, 63, 47], at: position) { return true }
        guard language == .cLike, units[position] == 92, let following = next(after: position) else { return false }
        // Java Unicode preprocessing и C/C++ line splicing действуют также внутри комментариев.
        if following == 117 { return true }
        var nextPosition = position + 1
        while nextPosition < units.count, [9, 11, 12, 32].contains(units[nextPosition]) { nextPosition += 1 }
        return nextPosition < units.count && isNewline(units[nextPosition])
    }

    private func isNewline(_ unit: UInt16) -> Bool {
        unit == 10 || unit == 13 || (language == .javascript && (unit == 0x2028 || unit == 0x2029))
    }

    private func isASCIILetter(_ unit: UInt16) -> Bool {
        (65...90).contains(unit) || (97...122).contains(unit)
    }
}
