import Foundation

/// readChecked сам проверяет полную цель/lease до и после AX; внешние IPC не дублируются.
@MainActor
enum UnicodeSelectionSettlement {
    static func wait(
        expected: SelectionSettlement.State,
        allowedSelections: [NSRange],
        canWait: () -> Bool,
        readChecked: () -> UnicodeTextSnapshot?,
        pause: () async -> Void
    ) async -> Bool {
        var matchingReads = 0
        for _ in 0..<4 {
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
