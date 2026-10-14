import ApplicationServices
import CoreGraphics
import Foundation

/// Мониторинг разрешений TCC (spec permissions-guard, design D5).
///
/// Опрашивает Accessibility и Input Monitoring по таймеру. При потере
/// любого разрешения вызывает `onPermissionsLost` (UI останавливает
/// перехват и показывает статус), при восстановлении — `onPermissionsRestored`.
public final class PermGuard {

    public struct Status: Equatable, Sendable {
        public let accessibility: Bool
        public let inputMonitoring: Bool

        public var allGranted: Bool { accessibility && inputMonitoring }
    }

    public var onPermissionsLost: @Sendable (Status) -> Void = { _ in }
    public var onPermissionsRestored: @Sendable () -> Void = {}

    public private(set) var current: Status

    private var timer: Timer?
    private let checkInterval: TimeInterval

    public init(checkInterval: TimeInterval = 5) {
        self.checkInterval = checkInterval
        self.current = Self.poll()
    }

    /// Разовый опрос текущего состояния разрешений.
    public static func poll() -> Status {
        Status(
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess()
        )
    }

    /// Запускает периодический опрос. Вызывать на главном потоке.
    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkNow()
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func checkNow() {
        let polled = Self.poll()
        let wasGranted = current.allGranted
        current = polled
        if wasGranted && !polled.allGranted {
            onPermissionsLost(polled)
        } else if !wasGranted && polled.allGranted {
            onPermissionsRestored()
        }
    }
}
