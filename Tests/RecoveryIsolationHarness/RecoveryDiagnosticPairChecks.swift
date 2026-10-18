import Foundation

/// Проверяется тот же packet flow, но packets — целые числа, post — запись в RAM.
@MainActor
enum RecoveryDiagnosticPairChecks {
    static func run() throws {
        try preparation()
        try refusedDown()
        try focusLossBalancesOnlyRelease()
        try identityLossLeavesExplicitDebt()
        try completedAndReentrantPairAreSingleUse()
        try balancingUsesOriginalTargetRoute()
        try routeParsingFailsClosed()
    }

    private static func preparation() throws {
        var prepared: [RecoveryDiagnosticPacketKind] = []
        let missingRelease = RecoveryDiagnosticPair<Int>.prepare { kind in
            prepared.append(kind)
            return kind == .down ? 1 : nil
        }
        try check(missingRelease == nil && prepared == [.down, .release], "both packets precede any post")
        let missingDown = RecoveryDiagnosticPair<Int>.prepare { _ in nil }
        try check(missingDown == nil, "missing down refuses whole preparation")
    }

    private static func refusedDown() throws {
        let pair = try preparedPair()
        var posts = 0
        var balanceChecks = 0
        let result = pair.dispatch(.init(canSubmit: { _, _ in false }, canBalance: { _ in
            balanceChecks += 1
            return true
        }, post: { _, _ in posts += 1 }))
        try check(result?.downAttempted == false && result?.releaseAttempted == false,
                  "refused Down has no release debt")
        try check(posts == 0 && balanceChecks == 0, "no unsolicited Up")
    }

    private static func focusLossBalancesOnlyRelease() throws {
        let pair = try preparedPair()
        var focused = true
        var posts: [Int] = []
        var balanceChecks = 0
        let result = pair.dispatch(.init(canSubmit: { _, _ in focused }, canBalance: { _ in
            balanceChecks += 1
            return true
        }, post: { kind, packet in
            posts.append(packet)
            if kind == .down { focused = false }
        }))
        try check(posts == [1, 2] && balanceChecks == 1, "cleanup Up survives focus loss")
        try check(result?.balancingRelease == true && result?.unpostedDebt == false, "balanced once")
        try check(result?.completed == false && result?.inconclusive == true, "partial normal pair stays inconclusive")
    }

    private static func identityLossLeavesExplicitDebt() throws {
        let pair = try preparedPair()
        var sameProcess = true
        var posts: [Int] = []
        let result = pair.dispatch(.init(canSubmit: { _, _ in sameProcess }, canBalance: { _ in sameProcess },
                                        post: { kind, packet in
            posts.append(packet)
            if kind == .down { sameProcess = false }
        }))
        sameProcess = true
        try check(posts == [1], "no Up to a replacement PID instance")
        try check(result?.unpostedDebt == true && result?.inconclusive == true, "unposted debt remains visible")
        try check(result?.releaseAttempted == false && result?.balancingRelease == false, "no invented release")
        try check(posts.count == 1, "restored identity alone never retries")
    }

    private static func completedAndReentrantPairAreSingleUse() throws {
        let pair = try preparedPair()
        var posts: [Int] = []
        var nestedAccepted = false
        let nested = RecoveryDiagnosticPair<Int>.Actions(
            canSubmit: { _, _ in true }, canBalance: { _ in true }, post: { _, _ in nestedAccepted = true }
        )
        let result = pair.dispatch(.init(canSubmit: { _, _ in true }, canBalance: { _ in
            nestedAccepted = true
            return true
        }, post: { _, packet in
            posts.append(packet)
            if pair.dispatch(nested) != nil { nestedAccepted = true }
        }))
        try check(posts == [1, 2] && !nestedAccepted, "ordinary Up is not repeated by defer or reentry")
        try check(result?.completed == true && result?.inconclusive == false, "complete local pair")
        try check(pair.dispatch(nested) == nil && !nestedAccepted, "prepared pair has one owner")
    }

    private static func balancingUsesOriginalTargetRoute() throws {
        for losesFocus in [false, true] {
            let pair = try preparedPair()
            var focused = true
            var global: [Int] = []
            var originalTarget: [Int] = []
            let result = pair.dispatch(.init(canSubmit: { _, _ in focused }, canBalance: { _ in true },
                                            post: { kind, packet in
                global.append(packet)
                if kind == .down && losesFocus { focused = false }
            }, balance: { originalTarget.append($0) }))
            try check(global == (losesFocus ? [1] : [1, 2]), "no global Up into a new foreground")
            try check(originalTarget == (losesFocus ? [2] : []), "only balancing release uses original PID")
            try check(result?.inconclusive == losesFocus, "fallback release does not certify normal pair")
        }
    }

    private static func routeParsingFailsClosed() throws {
        let flag = "--recovery-system-fault-route"
        try check(RecoveryDiagnosticRoute.parse([]) == .pid, "default remains addressed route")
        try check(RecoveryDiagnosticRoute.parse([flag + "=hid"]) == .hid, "explicit HID route")
        for values in [[flag], [flag + "="], [flag + "=unknown"], [flag + "extra=hid"],
                       [flag + "=hid", flag + "=pid"]] {
            try check(RecoveryDiagnosticRoute.parse(values) == nil, "malformed route refuses startup")
        }
    }

    private static func preparedPair() throws -> RecoveryDiagnosticPair<Int> {
        guard let pair = RecoveryDiagnosticPair<Int>.prepare({ $0 == .down ? 1 : 2 }) else {
            throw RecoveryIsolationMatrixChecks.Failure.failed("pair fixture")
        }
        return pair
    }

    private static func check(_ value: Bool, _ name: String) throws {
        try RecoveryIsolationMatrixChecks.require(value, name)
    }
}
