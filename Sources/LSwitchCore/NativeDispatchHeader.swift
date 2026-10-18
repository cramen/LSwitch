import CoreGraphics
import Darwin

/// Исключение своих команд из логического ввода. Не разрешает per-PID admission или replay.
enum NativeDispatchHeader {
    static func isOwnReservedEvent(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) else { return false }
        return matches(sender: Int64(getpid()), marker: event.getIntegerValueField(.eventSourceUserData))
    }

    static func matches(sender: Int64, marker: Int64) -> Bool {
        sender == Int64(getpid()) && NativeDispatchMarkers.shared?.containsReserved(marker) == true
    }
}
