import ApplicationServices
import Foundation

/// Конкретный reader гарантирует guards до/после всех getters; внешних callbacks за ними нет.
@MainActor
struct AXBoundedSnapshotAccess {
    let count: (AXUIElement) -> Int?
    let text: (AXUIElement, NSRange) -> String?
    let selection: (AXUIElement) -> NSRange?

    func read(_ element: AXUIElement, canRead: () -> Bool) -> AXProfileSnapshot? {
        AXProfileSnapshotReader(readCount: { count(element) }, readText: { text(element, $0) },
                                readSelection: { selection(element) }).read(canRead: canRead)
    }
}

/// Полный снимок разрешён лишь внутри отдельного editor-бюджета, независимо от квоты held input.
/// Parameterized provider получает только диапазон [0, count]; не поддержанный API не заменяется AXValue.
@MainActor
struct AXProfileSnapshotReader {
    let readCount: () -> Int?
    let readText: (NSRange) -> String?
    let readSelection: () -> NSRange?

    func read(canRead: () -> Bool) -> AXProfileSnapshot? {
        var denied = false
        func allowed() -> Bool {
            guard !denied, canRead() else { denied = true; return false }
            return true
        }
        guard allowed(), let count = readCount(), allowed(),
              count >= 0, count <= AXProfileSnapshot.maximumUTF16Units else { return nil }
        let range = NSRange(location: 0, length: count)
        // После закрывающего count guard были только pure bounds и создание NSRange.
        guard let text = readText(range), allowed(), text.utf16.count == count,
              let confirmedCount = readCount(), allowed(), confirmedCount == count,
              let selection = readSelection(), allowed() else { return nil }
        let snapshot = AXProfileSnapshot(text: text, selection: selection, characterCount: count)
        return snapshot.isComplete ? snapshot : nil
    }
}
