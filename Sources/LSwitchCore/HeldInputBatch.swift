import CoreGraphics
import Foundation

/// Закрытый RAM-владелец уже удержанных событий; не отправляет и не описывает payload.
/// После claim массив принадлежит единственному получателю, а batch больше его не хранит.
final class HeldInputBatch: @unchecked Sendable {
    let token: InputHoldToken
    /// Поколение исходного InputEventBuffer, не глобальный идентификатор процесса или tap.
    var generation: UInt64 { token.generation }
    let eventCount: Int
    private let lock = NSLock()
    private var events: [CGEvent]?

    init(token: InputHoldToken, events: [CGEvent]) {
        self.token = token
        self.eventCount = events.count
        self.events = events
    }

    /// Передаёт владение, но не разрешение replay: оно требует отдельного safety decision/ledger.
    /// nil означает прежний claim; пустой массив — успешно полученную пустую очередь.
    func claim() -> [CGEvent]? {
        lock.lock()
        defer { lock.unlock() }
        let claimed = events
        events = nil
        return claimed
    }
}
