#if DEBUG
import Foundation

/// Только собственный diagnostic Enable. Все реальные Carbon closures исполняются на child MainActor.
@MainActor
final class RecoverySecureInputDiagnosticLease {
    struct Environment {
        let isEnabled: () -> Bool
        let enable: () -> Bool
        let disable: () -> Bool
        let now: () -> UInt64
    }

    struct Snapshot {
        let enabled: Bool
        let owned: Bool
        let refused: Bool
        let enableCalls: Int
        let disableCalls: Int

        var flags: [String: Bool] { ["enabled": enabled, "owned": owned, "refused": refused] }
        var counts: [String: Int] { ["enable": enableCalls, "disable": disableCalls] }
    }

    static let maximumDuration: UInt64 = 2_000_000_000
    private enum Phase { case idle, enabling, active, ended }
    private let environment: Environment
    private var phase = Phase.idle
    private var stopRequested = false
    private var ownsEnable = false
    private var refused = false
    private var enableCalls = 0
    private var disableCalls = 0
    private var deadline: UInt64?

    init(environment: Environment) { self.environment = environment }

    @discardableResult
    func begin(permitted: Bool) -> Bool {
        guard phase == .idle else { return false }
        phase = .enabling
        guard permitted, !environment.isEnabled(), !stopRequested else {
            refused = true
            phase = .ended
            return false
        }
        enableCalls = 1
        ownsEnable = environment.enable()
        let end = environment.now().addingReportingOverflow(Self.maximumDuration)
        phase = .active
        guard ownsEnable, !stopRequested, !end.overflow else {
            refused = true
            stop()
            return false
        }
        deadline = end.partialValue
        return true
    }

    /// Disable выполняется не более одного раза и только после собственного успешного Enable.
    func stop() {
        if phase == .enabling { stopRequested = true; return }
        phase = .ended
        deadline = nil
        guard ownsEnable, disableCalls == 0 else { return }
        disableCalls = 1
        if environment.disable() { ownsEnable = false }
    }

    func expire() {
        guard phase == .active, let deadline, environment.now() >= deadline else { return }
        stop()
    }

    var snapshot: Snapshot {
        expire()
        let enabled = environment.isEnabled()
        return .init(enabled: enabled, owned: ownsEnable, refused: refused,
                     enableCalls: enableCalls, disableCalls: disableCalls)
    }
}
#endif
