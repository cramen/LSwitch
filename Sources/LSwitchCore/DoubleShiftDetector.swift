import CoreGraphics
import Foundation

/// Детект двойного нажатия Shift по потоку событий клавиатуры (design D1).
///
/// Чистый конечный автомат без системных вызовов — полностью покрыт
/// unit-тестами. Shift приходит как `flagsChanged` (keyCode 56 — левый,
/// 60 — правый, равнозначны); нажатие отличается от отпускания по флагу
/// `maskShift`. Любая другая клавиша между нажатиями сбрасывает автомат
/// (Shift+A не триггерит).
public struct DoubleShiftDetector: Sendable {

    /// Максимальный интервал между нажатиями, наносекунды (500 мс).
    public static let maxIntervalNanoseconds: UInt64 = 500_000_000

    private static let shiftKeyCodes: Set<UInt16> = [56, 60]

    private enum State: Equatable {
        case idle
        /// Первое нажатие Shift зафиксировано (timestamp события).
        case sawShiftDown(UInt64)
    }

    private var state: State = .idle

    public init() {}

    /// Возвращает true ровно один раз на втором нажатии Shift.
    public mutating func handle(_ event: RawKeyEvent) -> Bool {
        // Собственная синтетика (вставка конвертированного текста) не участвует.
        guard !event.isSynthetic else { return false }

        switch event.type {
        case .flagsChanged:
            return handleFlagsChanged(event)
        case .keyDown:
            state = .idle
            return false
        case .keyUp, .other:
            return false
        }
    }

    private mutating func handleFlagsChanged(_ event: RawKeyEvent) -> Bool {
        guard Self.shiftKeyCodes.contains(event.keyCode) else {
            // Другой модификатор (Cmd/Ctrl/Option) сбрасывает последовательность.
            state = .idle
            return false
        }
        let isShiftDown = event.modifierFlags & CGEventFlags.maskShift.rawValue != 0
        guard isShiftDown else { return false } // отпускание не меняет автомат

        switch state {
        case .idle:
            state = .sawShiftDown(event.timestamp)
            return false
        case .sawShiftDown(let firstTimestamp):
            state = .idle
            let interval = event.timestamp &- firstTimestamp
            return interval <= Self.maxIntervalNanoseconds
        }
    }
}
