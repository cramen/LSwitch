import Foundation

/// AX-setter может завершиться раньше обновления интерфейса. Стабильность требует
/// двух снимков после yield; чужой текст или диапазон прекращают ожидание сразу.
@MainActor
enum SelectionSettlement {
    typealias State = (text: String, selection: NSRange)

    /// Отмена операции запрещает новые записи, но не сокращает ожидание cleanup.
    static func pause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.02) {
                continuation.resume()
            }
        }
    }

    static func wait(
        expected: State,
        allowedSelections: [NSRange],
        isValid: () -> Bool,
        read: () -> State?,
        pause: () async -> Void
    ) async -> Bool {
        var matchingReads = 0
        for _ in 0..<4 {
            guard isValid() else { return false }
            await pause()
            guard isValid(), let current = read(), isValid(), current.text == expected.text,
                  allowedSelections.contains(current.selection) else { return false }
            matchingReads = current.selection == expected.selection ? matchingReads + 1 : 0
            if matchingReads == 2 { return true }
        }
        return false
    }
}
