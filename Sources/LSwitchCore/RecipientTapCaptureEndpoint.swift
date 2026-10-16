#if DEBUG
import CoreGraphics
import Foundation

/// Driver не владеет router/очередью. После detach остаются только неизменяемые fixture headers.
final class RecipientTapCaptureEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private weak var router: RecoveryCaptureRouter?
    private var filter: RecoveryFixtureCaptureFilter?
    private var identifier: UUID?

    func bind(
        router: RecoveryCaptureRouter, filter: RecoveryFixtureCaptureFilter, scope: RecoveryOperationTarget
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.filter == nil, router.matchesCapture(scope: scope, filter: filter) else { return false }
        self.router = router
        self.filter = filter
        identifier = router.identifier
        return true
    }

    /// Этот вызов всегда вне driver state lock: capture проверяет admission → slot → driver.
    func route(type: CGEventType, event: CGEvent) -> RecoveryCaptureRoute {
        guard type == .keyDown || type == .keyUp else { return .passThrough }
        lock.lock()
        let current = router
        let expected = filter
        let boundIdentifier = identifier
        lock.unlock()
        let sender = event.getIntegerValueField(.eventSourceUnixProcessID)
        let marker = event.getIntegerValueField(.eventSourceUserData)
        guard let expected, expected.ownsHeader(sender: sender, marker: marker) else { return .passThrough }
        // Поздний/неправильный пакет префикса не доставляется даже после исчезновения владельца.
        guard expected.matches(type: type, sender: sender, marker: marker), event.type == type,
              let current, current.identifier == boundIdentifier else { return .suppress }
        _ = current.route(type: type, event: event)
        return .suppress
    }
}
#endif
