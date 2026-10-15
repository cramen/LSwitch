#if DEBUG
@testable import LSwitchCore
import XCTest

@MainActor
final class UnicodePerformanceTests: XCTestCase {
    func testNestedInclusiveDurationsAreOverlappingAndBodyExecutesOnce() throws {
        var time: UInt64 = 0
        var executions = 0
        let metrics = UnicodePerformance(operationID: 42, now: { time })
        let value = metrics.measure(.snapshot) {
            time += 3
            metrics.measure(.documentIdentity) {
                time += 2
                metrics.measure(.isCurrent) { time += 5 }
                time += 1
            }
            time += 7
            executions += 1
            return true
        }
        XCTAssertTrue(value)
        XCTAssertEqual(executions, 1)
        let summary = try XCTUnwrap(metrics.finish(.blocked))
        XCTAssertEqual(summary.elapsedNanoseconds, 18)
        XCTAssertEqual(summary.aggregates[.snapshot], .init(calls: 1, inclusiveNanoseconds: 18))
        XCTAssertEqual(summary.aggregates[.documentIdentity], .init(calls: 1, inclusiveNanoseconds: 8))
        XCTAssertEqual(summary.aggregates[.isCurrent], .init(calls: 1, inclusiveNanoseconds: 5))
        XCTAssertTrue(summary.logLine.contains("scope=engine inclusive_overlapping=true"))
        XCTAssertNil(metrics.finish(.failed))
    }

    func testUnknownHostAndMissingRootAreSeparateFromTestedProvider() throws {
        let unknown = UnicodePerformance(operationID: 1, now: { 0 })
        unknown.recordProvider(bundleID: "com.microsoft.VSCode", version: "untrusted", documentRoot: false)
        let refused = try XCTUnwrap(unknown.finish(.blocked))
        XCTAssertEqual(refused.host, .unsupportedHost)
        XCTAssertEqual(refused.root, .missing)
        XCTAssertEqual(refused.outcome, .blocked)
        XCTAssertFalse(refused.logLine.contains("com.microsoft.VSCode"))
        XCTAssertFalse(refused.logLine.contains("untrusted"))

        let supported = UnicodePerformance(operationID: 2, now: { 0 })
        supported.recordProvider(bundleID: "com.google.Chrome", version: "155.0.8059.80", documentRoot: true)
        let accepted = try XCTUnwrap(supported.finish(.success(.init(original: "secret", converted: "private"))))
        XCTAssertEqual(accepted.host, .testedChrome)
        XCTAssertEqual(accepted.root, .present)
        XCTAssertEqual(accepted.outcome, .success)
        XCTAssertFalse(accepted.logLine.contains("secret"))
        XCTAssertFalse(accepted.logLine.contains("private"))
        XCTAssertTrue(accepted.logLine.contains("snapshot_calls=0 snapshot_inclusive_ns=0"))
    }

    func testTaskLocalScopesRemainSeparateAcrossYieldAndRestoreOuterScope() async throws {
        let outer = UnicodePerformance(operationID: 1, now: { 0 })
        let inner = UnicodePerformance(operationID: 2, now: { 0 })
        XCTAssertNil(UnicodePerformance.current)
        await UnicodePerformance.$current.withValue(outer) {
            UnicodePerformance.measure(.snapshot) {}
            await UnicodePerformance.$current.withValue(inner) {
                await Task.yield()
                UnicodePerformance.measure(.documentIdentity) {}
                UnicodePerformance.measure(.snapshot) {}
            }
            UnicodePerformance.measure(.snapshot) {}
        }
        XCTAssertNil(UnicodePerformance.current)
        let outerSummary = try XCTUnwrap(outer.finish(.blocked))
        let innerSummary = try XCTUnwrap(inner.finish(.failed))
        XCTAssertEqual(outerSummary.aggregates[.snapshot]?.calls, 2)
        XCTAssertNil(outerSummary.aggregates[.documentIdentity])
        XCTAssertEqual(innerSummary.aggregates[.snapshot]?.calls, 1)
        XCTAssertEqual(innerSummary.aggregates[.documentIdentity]?.calls, 1)
    }
}
#endif
