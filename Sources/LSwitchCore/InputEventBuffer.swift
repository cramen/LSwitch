import CoreGraphics
import Foundation

/// Короткая очередь ввода. Ограничители отменяют разрешение на запись;
/// выпуск начинается лишь после cleanup, чтобы не печатать в служебное выделение.
final class InputEventBuffer: @unchecked Sendable {
    static let maximumDuration: UInt64 = 400_000_000
    static let maximumCount = 256

    private let lock = NSLock()
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

    func begin(at now: UInt64) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard deadline == nil, now <= UInt64.max - Self.maximumDuration else { return nil }
        generation &+= 1
        deadline = now + Self.maximumDuration
        leaseValid = true
        return generation
    }

    /// Истечение бюджета запрещает продолжение мутации, но не выпускает события раньше cleanup.
    func expire(generation expected: UInt64, at now: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected, let deadline, now >= deadline else { return }
        leaseValid = false
    }

    func cancelLease() {
        lock.lock()
        leaseValid = false
        lock.unlock()
    }

    /// true означает, что исходный callback возвращает nil: объект сохранён для ровно одной доставки.
    func intercept(type: CGEventType, event: CGEvent, at now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let deadline, Self.canHold(type), !SyntheticEventMarker.isSynthetic(event) else { return false }
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
        for event in held { deliver(event) }
        held.removeAll(keepingCapacity: true)
        deadline = nil
        leaseValid = false
    }

    static func canHold(_ type: CGEventType) -> Bool {
        switch type {
        case .keyDown, .keyUp, .flagsChanged,
             .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return true
        default:
            return false
        }
    }
}
