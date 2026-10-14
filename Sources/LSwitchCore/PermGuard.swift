import ApplicationServices
import CoreGraphics
import Foundation

/// Мониторинг разрешений TCC (spec permissions-guard, design D5).
///
/// Опрашивает Accessibility и Input Monitoring по таймеру. При потере
/// любого разрешения вызывает `onPermissionsLost` (UI останавливает
/// перехват и показывает статус), при восстановлении — `onPermissionsRestored`.
@MainActor
public final class PermGuard {

    public struct Status: Equatable, Sendable {
        public let accessibility: Bool
        public let inputMonitoring: Bool

        public init(accessibility: Bool, inputMonitoring: Bool) {
            self.accessibility = accessibility
            self.inputMonitoring = inputMonitoring
        }

        public var allGranted: Bool { accessibility && inputMonitoring }
    }

    public var onPermissionsLost: (Status) -> Void = { _ in }
    public var onPermissionsRestored: () -> Void = {}
    public var onStatusChanged: (Status) -> Void = { _ in }

    public private(set) var current: Status

    private var timer: Timer?
    private let checkInterval: TimeInterval
    private let check: @MainActor () -> Status

    public init(checkInterval: TimeInterval = 5, check: @escaping @MainActor () -> Status = { PermGuard.poll() }) {
        precondition(checkInterval > 0)
        self.checkInterval = checkInterval
        self.check = check
        self.current = check()
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
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkNow() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func checkNow() {
        let polled = check()
        guard polled != current else { return }
        current = polled
        if !polled.allGranted {
            onPermissionsLost(polled)
        } else {
            onPermissionsRestored()
        }
        onStatusChanged(polled)
    }

    deinit { timer?.invalidate() }
}
