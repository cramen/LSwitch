#if DEBUG
import Foundation

public struct TextEditRecoveryInvocation: Equatable, Sendable {
    let runtime: UUID
    let identifier = UUID()
}

public enum TextEditRecoveryInterruption: Sendable {
    case focusChanged, off, permissionLost, tapLost, shutdown

    var logicalReason: EventProcessingInvalidation {
        switch self {
        case .focusChanged: return .focusChanged
        case .permissionLost: return .permissionLost
        case .off, .tapLost, .shutdown: return .stopped
        }
    }

    var stopsDriver: Bool {
        switch self {
        case .off, .permissionLost, .tapLost: return true
        case .focusChanged, .shutdown: return false
        }
    }
}

public struct TextEditRecoveryStatus: Equatable, Sendable {
    public let hasPending: Bool
    public let hasUnsettled: Bool
    public let metadataReady: Bool
}

enum TextEditRecoveryStage: String {
    case idle, invocation, profile, driver, logical, reserve, registered, armed, retained, completed, interrupted
}

@MainActor
public struct TextEditRecoveryInvocationActions {
    public let applyOutcome: @MainActor @Sendable (Converter.Outcome) -> Void
    public let reset: @MainActor @Sendable () -> Void
    public let consume: @MainActor @Sendable (RawKeyEvent) -> Void

    public init(
        applyOutcome: @escaping @MainActor @Sendable (Converter.Outcome) -> Void,
        reset: @escaping @MainActor @Sendable () -> Void,
        consume: @escaping @MainActor @Sendable (RawKeyEvent) -> Void
    ) {
        self.applyOutcome = applyOutcome
        self.reset = reset
        self.consume = consume
    }
}
#endif
