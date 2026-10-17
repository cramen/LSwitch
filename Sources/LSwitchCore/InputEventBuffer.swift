import CoreGraphics
import Foundation

/// Не содержит payload; совпадение номера поколения у разных очередей не даёт владения.
struct InputHoldToken: Hashable, Sendable {
    let generation: UInt64
    private let bufferIdentity: UUID

    fileprivate init(bufferIdentity: UUID, generation: UInt64) {
        self.bufferIdentity = bufferIdentity
        self.generation = generation
    }
}

/// Короткая очередь ввода. Ограничители отменяют разрешение на запись;
/// выпуск начинается лишь после cleanup, чтобы не печатать в служебное выделение.
final class InputEventBuffer: @unchecked Sendable {
    static let maximumDuration: UInt64 = 400_000_000
    static let maximumCount = 256

    private let lock = NSLock()
    private let identity = UUID()
    private var deadline: UInt64?
    private var generation: UInt64 = 0
    private var leaseValid = false
    private var held: [CGEvent] = []

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deadline != nil
    }

    var isHolding: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deadline != nil && leaseValid
    }

    /// Совместимость: числовое поколение не доказывает принадлежность конкретной очереди.
    func begin(at now: UInt64) -> UInt64? {
        beginHold(at: now)?.generation
    }

    func beginHold(at now: UInt64) -> InputHoldToken? {
        lock.lock()
        defer { lock.unlock() }
        guard deadline == nil, generation < UInt64.max, now <= UInt64.max - Self.maximumDuration else { return nil }
        generation += 1
        deadline = now + Self.maximumDuration
        leaseValid = true
        return currentTokenLocked
    }

    /// Истечение бюджета запрещает продолжение мутации, но не выпускает события раньше cleanup.
    /// Legacy API: поколение принадлежит вызывающему buffer, identity отдельно не проверяется.
    func expire(generation expected: UInt64, at now: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected, let deadline, now >= deadline else { return }
        leaseValid = false
    }

    func expire(token: InputHoldToken, at now: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard token == currentTokenLocked, let deadline, now >= deadline else { return }
        leaseValid = false
    }

    func cancelLease() {
        lock.lock()
        leaseValid = false
        lock.unlock()
    }

    /// true означает, что исходный callback возвращает nil: объект сохранён для ровно одной доставки.
    func intercept(type: CGEventType, event: CGEvent, at now: UInt64) -> Bool {
        intercept(type: type, event: event, at: now, legacyPolicy: true)
    }

    /// Scoped port уже проверил own-marker registry. Общая magic-константа не доказывает происхождение.
    func captureAuthorized(_ event: CGEvent, at now: UInt64) -> Bool {
        intercept(type: event.type, event: event, at: now, legacyPolicy: false)
    }

    private func intercept(
        type: CGEventType, event: CGEvent, at now: UInt64, legacyPolicy: Bool
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let deadline, Self.canHold(type),
              !legacyPolicy || (type != .scrollWheel && !SyntheticEventMarker.isSynthetic(event)) else { return false }
        if now >= deadline { leaseValid = false }
        // При невозможности копии удерживаем сам объект: ARC сохраняет его после callback.
        held.append(event.copy() ?? event)
        if held.count >= Self.maximumCount { leaseValid = false }
        return true
    }

    /// Доставка идёт ниже нашего tap, поэтому не вызывает повторный intercept.
    /// Замок закрывает промежуток между публикацией сохранённого ввода и допуском нового.
    func end(deliver: (CGEvent) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        finishLocked(deliver: deliver)
    }

    /// Завершает только указанную очередь/поколение; допустимость доставки решает внешний safety ledger.
    @discardableResult
    func end(token: InputHoldToken, deliver: (CGEvent) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard deadline != nil, token == currentTokenLocked else { return false }
        finishLocked(deliver: deliver)
        return true
    }

    /// Вызывается только под lock: публикация очереди и её закрытие неделимы для intercept/detach.
    private func finishLocked(deliver: (CGEvent) -> Void) {
        for event in held { deliver(event) }
        held.removeAll(keepingCapacity: true)
        deadline = nil
        leaseValid = false
    }

    /// Пустой batch сохраняет факт передачи даже при неподтверждённом выделении без нового ввода.
    func detach(token: InputHoldToken) -> HeldInputBatch? {
        lock.lock()
        defer { lock.unlock() }
        guard deadline != nil, token == currentTokenLocked else { return nil }
        return detachLocked()
    }

    /// Оба helper вызываются только под lock исходного buffer.
    private var currentTokenLocked: InputHoldToken {
        InputHoldToken(bufferIdentity: identity, generation: generation)
    }

    private func detachLocked() -> HeldInputBatch {
        let batch = HeldInputBatch(token: currentTokenLocked, events: held)
        held = []
        deadline = nil
        leaseValid = false
        return batch
    }

    static func canHold(_ type: CGEventType) -> Bool {
        switch type {
        case .keyDown, .keyUp, .flagsChanged,
             .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel:
            return true
        default:
            return false
        }
    }
}
