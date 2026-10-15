import Foundation

/// readChecked сам проверяет полную цель/lease до и после AX; внешние IPC не дублируются.
@MainActor
enum UnicodeSelectionSettlement {
    static func wait(
        expected: SelectionSettlement.State,
        allowedSelections: [NSRange],
        initialObservation: UnicodeTextSnapshot? = nil,
        canWait: () -> Bool,
        readChecked: () -> UnicodeTextSnapshot?,
        pause: () async -> Void
    ) async -> Bool {
        let initialMatches = initialObservation.map {
            $0.isComplete && $0.matches(text: expected.text, selection: expected.selection)
                && allowedSelections.contains($0.selection)
        } ?? false
        var matchingReads = initialMatches ? 1 : 0
        // Уже проверенный snapshot — одно наблюдение, не разрешение пропустить свежий read.
        let remainingReads = 4 - matchingReads
        for _ in 0..<remainingReads {
            guard canWait() else { return false }
            await pause()
            guard let current = readChecked(), current.text.utf16.elementsEqual(expected.text.utf16),
                  allowedSelections.contains(current.selection) else { return false }
            matchingReads = current.selection == expected.selection ? matchingReads + 1 : 0
            if matchingReads == 2 { return true }
        }
        return false
    }
}
