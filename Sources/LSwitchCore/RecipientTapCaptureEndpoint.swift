#if DEBUG
import CoreGraphics
import Foundation

/// Driver не владеет router/очередью. После detach остаются только metadata policy и own-marker predicate.
final class RecipientTapCaptureEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private weak var router: RecoveryCaptureRouter?
    private var tombstone: RecoveryCaptureTombstone?
    private var identifier: UUID?

    func bind(
        router: RecoveryCaptureRouter, filter: RecoveryFixtureCaptureFilter, scope: RecoveryOperationTarget
    ) -> Bool {
        bind(router: router, policy: .fixture(filter), scope: scope)
    }

    func bindRecipientInput(router: RecoveryCaptureRouter, scope: RecoveryOperationTarget) -> Bool {
        bind(router: router, policy: .recipientInput, scope: scope)
    }

    private func bind(
        router: RecoveryCaptureRouter, policy: RecoveryCapturePolicy, scope: RecoveryOperationTarget
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard tombstone == nil,
              let captured = router.captureTombstone(scope: scope, policy: policy) else { return false }
        self.router = router
        tombstone = captured
        identifier = router.identifier
        return true
    }

    var isFixtureBinding: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .fixture = tombstone?.policy { return true }
        return false
    }

    /// Этот вызов всегда вне driver state lock: capture проверяет admission → slot → driver.
    func route(type: CGEventType, event: CGEvent) -> RecoveryCaptureRoute {
        lock.lock()
        let current = router
        let expected = tombstone
        let boundIdentifier = identifier
        lock.unlock()
        let sender = event.getIntegerValueField(.eventSourceUnixProcessID)
        let marker = event.getIntegerValueField(.eventSourceUserData)
        guard let expected, expected.suppresses(type: type, event: event) else { return .passThrough }
        // Поздний/неправильный пакет префикса не доставляется даже после исчезновения владельца.
        guard expected.policy.matches(type: type, sender: sender, marker: marker), event.type == type,
              let current, current.identifier == boundIdentifier else { return .suppress }
        return current.route(type: type, event: event) == .passThrough ? .passThrough : .suppress
    }
}
#endif
