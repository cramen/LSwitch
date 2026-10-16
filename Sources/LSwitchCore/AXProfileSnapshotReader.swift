import Foundation

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
        guard allowed(), let text = readText(range), allowed(), text.utf16.count == count,
              let confirmedCount = readCount(), allowed(), confirmedCount == count,
              let selection = readSelection(), allowed() else { return nil }
        let snapshot = AXProfileSnapshot(text: text, selection: selection, characterCount: count)
        return snapshot.isComplete ? snapshot : nil
    }
}
