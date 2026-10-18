import Foundation

/// Все эффекты заменены RAM closures. Carbon API, Process и системные события не вызываются.
@MainActor
enum RecoverySecureInputChecks {
    static func run() throws {
        try balancedLeaseAndTTL()
        try refusedAndReentrantLease()
        try secureWire()
        try watchdog()
    }

    private static func balancedLeaseAndTTL() throws {
        let memory = SecureLeaseMemory()
        let lease = memory.lease()
        try check(lease.begin(permitted: true), "secure lease begins once")
        try check(!lease.begin(permitted: true) && memory.enables == 1, "no nested enable count")
        memory.time = 1_999_999_999
        lease.expire()
        try check(memory.disables == 0, "TTL is not early")
        memory.time += 1
        lease.expire()
        lease.stop()
        try check(memory.disables == 1 && !memory.enabled, "TTL balances once")
        try check(!lease.snapshot.owned && !lease.begin(permitted: true), "closed lease never rearms")
        let early = SecureLeaseMemory()
        let earlyLease = early.lease()
        try check(earlyLease.begin(permitted: true), "second independent lease")
        earlyLease.stop()
        early.time = 5_000_000_000
        earlyLease.expire()
        try check(early.disables == 1, "inactivity or EOF followed by TTL cannot double disable")
    }

    private static func refusedAndReentrantLease() throws {
        let baseline = SecureLeaseMemory()
        baseline.enabled = true
        let refused = baseline.lease()
        try check(!refused.begin(permitted: true), "existing secure input is not ours")
        refused.stop()
        try check(baseline.enables == 0 && baseline.disables == 0 && baseline.enabled, "external counter untouched")
        let stoppedBeforeStart = SecureLeaseMemory()
        stoppedBeforeStart.enabled = true
        let neverEnabled = stoppedBeforeStart.lease()
        neverEnabled.stop()
        try check(!neverEnabled.begin(permitted: true) && stoppedBeforeStart.disables == 0,
                  "stop before own enable cannot change another process counter")
        let reentry = SecureLeaseMemory()
        let interrupted = reentry.lease()
        reentry.onEnable = { interrupted.stop() }
        try check(!interrupted.begin(permitted: true), "stop during enable refuses active lease")
        try check(reentry.enables == 1 && reentry.disables == 1 && !interrupted.snapshot.owned, "reentrant balance")
        let failed = SecureLeaseMemory()
        failed.disableSucceeds = false
        let failure = failed.lease()
        try check(failure.begin(permitted: true), "enable before failed cleanup")
        failure.stop()
        failure.stop()
        try check(failure.snapshot.owned && failed.disables == 1, "failed disable is not successful balance")
        let overflow = SecureLeaseMemory()
        overflow.time = UInt64.max
        let overflowLease = overflow.lease()
        try check(!overflowLease.begin(permitted: true) && overflow.disables == 1, "overflow safely balances")
    }

    private static func secureWire() throws {
        var fields = RecoveryIsolationMatrixChecks.envelope(kind: "secure_input")
        fields["secure"] = ["enabled": true, "owned": true, "refused": false]
        fields["secureCounts"] = ["enable": 1, "disable": 0]
        let active = try RecoveryIsolationMatrixChecks.decode(fields)
        try check(active.secure["owned"] == true && active.secureCounts["enable"] == 1, "typed secure metadata")
        fields["windowTitle"] = "LSwitch Isolation Receiver \(RecoveryIsolationMatrixChecks.nonce)"
        fields["windowCleanupCompleted"] = true
        fields["reason"] = "observation_overflow"
        fields["sequence"] = 32
        fields["received"] = Array(repeating: "challengeRelease", count: 16)
        fields["changeCount"] = 256
        try check(try RecoveryIsolationMatrixChecks.requireFrame(fields).count <= 1024, "bounded secure frame")
        let invalid: [[String: Any]] = [
            ["secure": ["enabled": "forbidden", "owned": true, "refused": false]],
            ["secure": ["enabled": true, "owned": true, "refused": false, "extra": true]],
            ["secureCounts": ["enable": 2, "disable": 0]],
            ["secureCounts": ["enable": 0, "disable": 1]],
            ["secureCounts": ["enable": true, "disable": false]],
            ["matrixArmed": true]
        ]
        for update in invalid {
            var changed = fields
            update.forEach { changed[$0.key] = $0.value }
            try check(RecoveryIsolationMatrixChecks.rejected(changed), "invalid secure frame")
        }
        try check(RecoveryIsolationMatrixChecks.rejected(
            RecoveryIsolationMatrixChecks.envelope(kind: "secure_input")), "secure reply requires state")
        for command in ["secureInputOn", "secureInputOff"] {
            let frame: [String: Any] = ["v": 1, "nonce": RecoveryIsolationMatrixChecks.nonce,
                                       "sequence": 1, "command": command]
            let data = try JSONSerialization.data(withJSONObject: frame)
            try check(RecoveryIsolationWire.decode(data, nonce: RecoveryIsolationMatrixChecks.nonce,
                                                   expectedSequence: 1)?.command.rawValue == command, "bounded command")
        }
    }

    private static func watchdog() throws {
        let counter = SecureWatchdogCounter()
        let cancelled = RecoveryIsolationSecureWatchdog()
        var delayed: (@Sendable () -> Void)?
        try check(cancelled.arm(action: { counter.increment() }, schedule: { delayed = $0 }), "watchdog arm")
        cancelled.cancel()
        delayed?()
        try check(!cancelled.didFire && counter.value == 0, "cancel suppresses delayed action")
        let fired = RecoveryIsolationSecureWatchdog()
        try check(fired.arm(action: { counter.increment(); fired.cancel() }, schedule: { delayed = $0 }), "fresh arm")
        delayed?()
        delayed?()
        try check(fired.didFire && counter.value == 1, "one action outside lock")
        try check(!fired.arm(action: { counter.increment() }, schedule: { delayed = $0 }), "no rearm")
    }

    private static func check(_ value: Bool, _ name: String) throws {
        try RecoveryIsolationMatrixChecks.require(value, name)
    }
}

@MainActor
private final class SecureLeaseMemory {
    var enabled = false
    var enables = 0
    var disables = 0
    var disableSucceeds = true
    var time: UInt64 = 0
    var onEnable: () -> Void = {}

    func lease() -> RecoverySecureInputDiagnosticLease {
        .init(environment: .init(isEnabled: { self.enabled }, enable: {
            self.enables += 1
            self.enabled = true
            self.onEnable()
            return true
        }, disable: {
            self.disables += 1
            if self.disableSucceeds { self.enabled = false }
            return self.disableSucceeds
        }, now: { self.time }))
    }
}

private final class SecureWatchdogCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
