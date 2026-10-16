import Foundation

/// Только решение о завершении приложения; не разрешение доставки или снятия защиты цели.
@MainActor
public enum RecoveryQuitPresentationRequest {
    case allowed
    case handoverRequired
    case confirmationRequired(RecoveryQuitConfirmation)
}

/// Одноразовый мост к внутреннему quit intent. Содержимое RAM наружу не передаётся.
@MainActor
public final class RecoveryQuitConfirmation {
    public let recordIdentifier: UUID
    private let confirmation: () -> Bool
    private let cancellation: () -> Void
    private var resolved = false

    public init(recordIdentifier: UUID, confirm: @escaping () -> Bool, cancel: @escaping () -> Void) {
        self.recordIdentifier = recordIdentifier
        confirmation = confirm
        cancellation = cancel
    }

    func confirm() -> Bool {
        guard !resolved else { return false }
        resolved = true
        return confirmation()
    }

    func cancel() {
        guard !resolved else { return }
        resolved = true
        cancellation()
    }
}

@MainActor
public struct RecoveryQuitActions {
    let request: () -> RecoveryQuitPresentationRequest

    public init(request: @escaping () -> RecoveryQuitPresentationRequest) { self.request = request }
}

public struct RecoveryWindowQuitIntent: Equatable, Sendable {
    let session: UUID
    let record: UUID
    let nonce = UUID()
}

public enum RecoveryWindowQuitRequest: Equatable, Sendable {
    case allowed, handoverRequired
    case confirmationRequired(RecoveryWindowQuitIntent)
}

public enum RecoveryWindowQuitResolution: Equatable, Sendable { case cancelled, quitAllowed, refused, stale }

extension RecoveryCoordinator {
    var quitActions: RecoveryQuitActions {
        .init { [weak self] in
            guard let self else { return .handoverRequired }
            switch self.requestQuit() {
            case .allowed: return .allowed
            case .handoverRequired: return .handoverRequired
            case .confirmationRequired(let intent):
                guard let record = self.metadata?.identifier else { return .handoverRequired }
                return .confirmationRequired(.init(recordIdentifier: record, confirm: { [weak self] in
                    self?.decideQuit(intent, choice: .deleteAndQuit) == .quitAllowed
                }, cancel: { [weak self] in _ = self?.decideQuit(intent, choice: .stay) }))
            }
        }
    }
}
