import Dispatch
import Foundation

struct AXProfileTiming: Equatable, Sendable {
    private(set) var count: UInt64 = 0
    private(set) var nanoseconds: UInt64 = 0

    mutating func record(nanoseconds elapsed: UInt64) {
        count = Self.add(count, 1)
        nanoseconds = Self.add(nanoseconds, elapsed)
    }

    private static func add(_ first: UInt64, _ second: UInt64) -> UInt64 {
        let sum = first.addingReportingOverflow(second)
        return sum.overflow ? UInt64.max : sum.partialValue
    }
}

/// Значения после prepare профиля. Snapshot inclusive включает вложенные измеренные guards.
struct AXProfileDiagnosticReport: Equatable, Sendable {
    let requestIsValid: AXProfileTiming
    let source: AXProfileTiming
    let protectedField: AXProfileTiming
    let focus: AXProfileTiming
    let context: AXProfileTiming
    let foreground: AXProfileTiming
    let snapshotInclusive: AXProfileTiming
    let profileFault: ConversionSafetyProfileFault?
}

enum AXProfileTimingCategory: Hashable {
    case requestIsValid, source, protectedField, focus, context, foreground, snapshot
}

/// В hot path нет observers, форматирования или произвольного clock callback.
@MainActor
final class AXProfileDiagnostics {
    private var timings: [AXProfileTimingCategory: AXProfileTiming] = [:]

    func measure<Value>(_ category: AXProfileTimingCategory, _ body: () -> Value) -> Value {
        #if DEBUG
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            let endedAt = DispatchTime.now().uptimeNanoseconds
            timings[category, default: .init()].record(nanoseconds: endedAt >= startedAt ? endedAt - startedAt : 0)
        }
        #endif
        return body()
    }

    func report(fault: ConversionSafetyProfileFault?) -> AXProfileDiagnosticReport {
        .init(requestIsValid: timings[.requestIsValid, default: .init()], source: timings[.source, default: .init()],
              protectedField: timings[.protectedField, default: .init()], focus: timings[.focus, default: .init()],
              context: timings[.context, default: .init()], foreground: timings[.foreground, default: .init()],
              snapshotInclusive: timings[.snapshot, default: .init()],
              profileFault: fault)
    }
}
