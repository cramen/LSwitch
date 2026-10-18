import Foundation

/// Тот же continuation gate, что в App-flow; вместо start/disable/retire — явный async barrier.
@MainActor
enum RecoverySystemFaultContinuationChecks {
    static func run() async throws {
        try await stoppedContinuation("start", counters: ["arm", "prefix"])
        try await stoppedContinuation("disable", counters: ["retire", "challenge"])
        try await stoppedContinuation("retire", counters: ["challenge"])
        try await stoppedBeforeStartAndQuitCancel()
        try await normalAndRefusedContinuation()
        try secureObservationReentry()
        try watchdogBeforeEnable()
        try stopStillBalancesRelease()
    }

    private static func stoppedContinuation(_ name: String, counters: [String]) async throws {
        let gate = RecoverySystemFaultContinuation()
        let barrier = Barrier()
        var actions: [String] = []
        var quitPending = false
        let pending = Task { @MainActor in
            await gate.after({
                actions.append(name)
                return await barrier.wait()
            }) { actions.append(contentsOf: counters) }
        }
        await barrier.waitUntilEntered()
        quitPending = true
        gate.stop()
        quitPending = false
        barrier.resume(true)
        let result = await pending.value
        try check(!quitPending && result == .stopped && actions == [name],
                  "late \(name) cannot arm or post after Quit and Cancel")
    }

    private static func stoppedBeforeStartAndQuitCancel() async throws {
        let gate = RecoverySystemFaultContinuation()
        var quitPending = true
        var calls = 0
        gate.stop()
        quitPending = false
        let result = await gate.after({ calls += 1; return true }) { calls += 1 }
        try check(!quitPending && result == .stopped && calls == 0, "cancelled Quit never reopens test actions")
        try check(!gate.ifCurrent(after: { calls += 1 }, then: { calls += 1 }), "stopped observation is inert")
        try check(calls == 0, "no observation side effect after stop")
    }

    private static func normalAndRefusedContinuation() async throws {
        let gate = RecoverySystemFaultContinuation()
        let barrier = Barrier()
        var actions: [String] = []
        let pending = Task { @MainActor in
            await gate.after({ actions.append("start"); return await barrier.wait() }) {
                actions.append(contentsOf: ["arm", "prefix"])
            }
        }
        await barrier.waitUntilEntered()
        try check(actions == ["start"], "no continuation before actual asynchronous return")
        barrier.resume(true)
        let result = await pending.value
        try check(result == .completed && actions == ["start", "arm", "prefix"], "normal ordering")
        let refused = await gate.after({ false }) { actions.append("unexpected") }
        try check(refused == .refused && actions.count == 3, "refused operation cannot continue")
    }

    private static func secureObservationReentry() throws {
        let gate = RecoverySystemFaultContinuation()
        var observed = 0
        var actions = 0
        let continued = gate.ifCurrent(after: {
            observed += 1
            gate.stop()
        }, then: { actions += 1 })
        try check(!continued && observed == 1 && actions == 0, "secure observer may close gate before arm/send")
    }

    private static func watchdogBeforeEnable() throws {
        let gate = RecoverySystemFaultContinuation()
        var actions: [String] = []
        let refused = gate.prepareThenSend(prepare: { actions.append("arm-refused"); return false },
                                          send: { actions.append("enable"); return true })
        try check(!refused && actions == ["arm-refused"], "Enable requires armed watchdog")
        let sendFailed = gate.prepareThenSend(prepare: { actions.append("armed"); return true },
                                             send: { actions.append("send-failed"); return false })
        try check(!sendFailed && actions == ["arm-refused", "armed", "send-failed"],
                  "failed send keeps watchdog; no cancellation action")
        let stopped = gate.prepareThenSend(prepare: { gate.stop(); return true },
                                          send: { actions.append("late-enable"); return true })
        try check(!stopped && actions.count == 3, "Quit during preparation forbids Enable")
    }

    private static func stopStillBalancesRelease() throws {
        let gate = RecoverySystemFaultContinuation()
        guard let pair = RecoveryDiagnosticPair<Int>.prepare({ $0 == .down ? 1 : 2 }) else {
            throw RecoveryIsolationMatrixChecks.Failure.failed("pair fixture")
        }
        var posts: [Int] = []
        let result = pair.dispatch(.init(canSubmit: { _, _ in gate.isOpen }, canBalance: { _ in true },
                                        post: { kind, packet in
            posts.append(packet)
            if kind == .down { gate.stop() }
        }))
        try check(posts == [1, 2] && result?.balancingRelease == true, "Quit permits only original balancing Up")
        try check(result?.inconclusive == true && result?.unpostedDebt == false,
                  "balanced partial flow is inconclusive")
    }

    private static func check(_ value: Bool, _ name: String) throws {
        try RecoveryIsolationMatrixChecks.require(value, name)
    }

    @MainActor
    private final class Barrier {
        private var pending: CheckedContinuation<Bool, Never>?
        private var entered: CheckedContinuation<Void, Never>?

        func wait() async -> Bool {
            await withCheckedContinuation { pending in
                self.pending = pending
                entered?.resume()
                entered = nil
            }
        }

        func waitUntilEntered() async {
            guard pending == nil else { return }
            await withCheckedContinuation { entered = $0 }
        }

        func resume(_ accepted: Bool) {
            let current = pending
            pending = nil
            current?.resume(returning: accepted)
        }
    }
}
