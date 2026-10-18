import Foundation

/// Номера не переиспользуются в течение процесса, в том числе после отказа/закрытия registry.
/// Namespace и serial занимают 52 бита: последующая системная проверка roundtrip всё равно обязательна.
/// Число не аутентифицирует источник: native adapter отдельно проверяет собственный source Unix PID.
final class NativeDispatchMarkers: @unchecked Sendable {
    private static let namespaces = NativeMarkerCounter(limit: (1 << 20) - 1)
    static let shared = NativeDispatchMarkers()

    private let namespace: UInt64
    private let serials: NativeMarkerCounter

    init?(serialLimit: UInt64 = UInt64(UInt32.max)) {
        guard serialLimit > 0, serialLimit <= UInt64(UInt32.max),
              let namespace = Self.namespaces.take(1)?.first else { return nil }
        self.namespace = namespace
        self.serials = NativeMarkerCounter(limit: serialLimit)
    }

    func reserve(_ count: Int) -> [Int64]? {
        guard count > 0, count <= 256, let serials = serials.take(count) else { return nil }
        return serials.map { Int64((namespace << 32) | $0) }
    }

    /// Только ранее выделенный номер этого namespace, включая закрытые поколения; не admission.
    func containsReserved(_ marker: Int64) -> Bool {
        guard marker > 0 else { return false }
        let value = UInt64(marker)
        guard value >> 32 == namespace else { return false }
        return serials.containsAllocated(value & UInt64(UInt32.max))
    }
}

/// Только арифметика под lock. Нет чтения времени, случайных источников, payload или системных вызовов.
private final class NativeMarkerCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: UInt64
    private var allocated: UInt64 = 0

    init(limit: UInt64) { self.limit = limit }

    func containsAllocated(_ serial: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return serial > 0 && serial <= allocated
    }

    func take(_ count: Int) -> [UInt64]? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0, UInt64(count) <= limit - allocated else { return nil }
        let start = allocated + 1
        allocated += UInt64(count)
        return Array(start...allocated)
    }
}
