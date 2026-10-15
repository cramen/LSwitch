#if DEBUG
import Dispatch
import Foundation
import os

/// Вложенные интервалы inclusive: суммировать три категории как wall time нельзя.
@MainActor
final class UnicodePerformance {
    enum Stage: String, CaseIterable { case isCurrent, documentIdentity, snapshot }
    enum Host: String { case contextUnavailable, unsupportedHost, unverifiedVersion, testedChrome }
    enum Root: String { case unknown, missing, present }
    enum Outcome: String { case success, unavailable, blocked, failed }

    struct Aggregate: Equatable {
        var calls: UInt64 = 0
        var inclusiveNanoseconds: UInt64 = 0
    }

    struct Summary {
        let operationID: UInt64
        let host: Host
        let root: Root
        let outcome: Outcome
        let elapsedNanoseconds: UInt64
        let aggregates: [Stage: Aggregate]

        var logLine: String {
            let fields = Stage.allCases.map { stage in
                let value = aggregates[stage] ?? Aggregate()
                return "\(stage.rawValue)_calls=\(value.calls)"
                    + " \(stage.rawValue)_inclusive_ns=\(value.inclusiveNanoseconds)"
            }.joined(separator: " ")
            return "unicode_profile id=\(operationID) scope=engine inclusive_overlapping=true"
                + " host=\(host.rawValue) root=\(root.rawValue) outcome=\(outcome.rawValue)"
                + " elapsed_ns=\(elapsedNanoseconds) " + fields
        }
    }

    @TaskLocal static var current: UnicodePerformance?
    private static var nextID: UInt64 = 0
    private static let logger = Logger(subsystem: "LSwitch", category: "UnicodePerformance")
    private let operationID: UInt64
    private let now: () -> UInt64
    private let startedAt: UInt64
    private var aggregates: [Stage: Aggregate] = [:]
    private var host: Host = .contextUnavailable
    private var root: Root = .unknown
    private var finished = false

    init(operationID: UInt64, now: @escaping () -> UInt64) {
        self.operationID = operationID
        self.now = now
        self.startedAt = now()
    }

    static func profile(_ operation: @MainActor () async -> ConversionResult) async -> ConversionResult {
        nextID &+= 1
        let metrics = UnicodePerformance(operationID: nextID, now: { DispatchTime.now().uptimeNanoseconds })
        let result = await $current.withValue(metrics) { await operation() }
        if let summary = metrics.finish(result) {
            logger.notice("\(summary.logLine, privacy: .public)")
        }
        return result
    }

    static func measure<Value>(_ stage: Stage, _ operation: () -> Value) -> Value {
        guard let current else { return operation() }
        return current.measure(stage, operation)
    }

    func measure<Value>(_ stage: Stage, _ operation: () -> Value) -> Value {
        let start = now()
        defer {
            let end = now()
            var total = aggregates[stage] ?? Aggregate()
            total.calls &+= 1
            total.inclusiveNanoseconds &+= end >= start ? end - start : 0
            aggregates[stage] = total
        }
        return operation()
    }

    func recordProvider(bundleID: String?, version: String?, documentRoot: Bool) {
        if bundleID != "com.google.Chrome" {
            host = .unsupportedHost
        } else {
            host = version == UnicodeSnapshotPolicy.testedVersion ? .testedChrome : .unverifiedVersion
        }
        root = documentRoot ? .present : .missing
    }

    func finish(_ result: ConversionResult) -> Summary? {
        guard !finished else { return nil }
        finished = true
        let outcome: Outcome
        switch result {
        case .success: outcome = .success
        case .unavailable: outcome = .unavailable
        case .blocked: outcome = .blocked
        case .failed: outcome = .failed
        }
        let endedAt = now()
        return Summary(operationID: operationID, host: host, root: root, outcome: outcome,
                       elapsedNanoseconds: endedAt >= startedAt ? endedAt - startedAt : 0, aggregates: aggregates)
    }
}
#endif
