#if DEBUG
import CoreGraphics
import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

final class EventTapMetricsTests: XCTestCase {
    func testHistogramKeepsExactBudgetBoundaryAndMaximum() {
        let metrics = EventTapMetrics(startedAt: 100)
        for duration: UInt64 in [0, 10_000, 10_001, 1_000_000, 1_000_001, 8_000_000] {
            metrics.recordCallback(durationNanoseconds: duration)
        }
        let snapshot = metrics.snapshot(state: "running", tapEnabled: true, now: 1_000_000_100)
        XCTAssertEqual(snapshot.callbackCount, 6)
        XCTAssertEqual(snapshot.maximumCallbackNanoseconds, 8_000_000)
        XCTAssertEqual(snapshot.callbacksOverOneMillisecond, 2)
        XCTAssertEqual(snapshot.histogramCounts.reduce(0, +), 6)
        XCTAssertEqual(snapshot.histogramCounts[0], 2)
        XCTAssertEqual(snapshot.histogramCounts[1], 1)
        XCTAssertEqual(snapshot.histogramCounts[6], 1)
        XCTAssertEqual(snapshot.histogramCounts.last, 1)
        XCTAssertNil(snapshot.p99UpperBoundNanoseconds, "Переполнение p99 не должно выглядеть как 5 мс")
        XCTAssertEqual(snapshot.uptimeSeconds, 1)
    }

    func testP99DoesNotHideSlowestCallbackOrViolation() {
        let metrics = EventTapMetrics(startedAt: 0)
        for _ in 0..<99 { metrics.recordCallback(durationNanoseconds: 40_000) }
        metrics.recordCallback(durationNanoseconds: 6_000_000)
        let snapshot = metrics.snapshot(state: "running", tapEnabled: true, now: 1)
        XCTAssertEqual(snapshot.p99UpperBoundNanoseconds, 50_000)
        XCTAssertEqual(snapshot.maximumCallbackNanoseconds, 6_000_000)
        XCTAssertEqual(snapshot.callbacksOverOneMillisecond, 1)
    }

    func testEmptyHistogramDoesNotClaimMeasuredLatency() {
        let metrics = EventTapMetrics(startedAt: 100)
        let snapshot = metrics.snapshot(state: "stopped", tapEnabled: false, now: 99)
        XCTAssertEqual(snapshot.callbackCount, 0)
        XCTAssertNil(snapshot.p99UpperBoundNanoseconds)
        XCTAssertEqual(snapshot.uptimeSeconds, 0)
    }

    func testHoldInvalidationIsCountedOnceAndReleaseIsSeparate() {
        let metrics = EventTapMetrics()
        metrics.increment(.holdGrants)
        metrics.increment(.heldEvents, by: 3)
        metrics.invalidateHold()
        metrics.invalidateHold()
        metrics.finishHold(released: 3)
        metrics.increment(.holdRefusals)
        metrics.increment(.holdGrants)
        metrics.finishHold(released: 0)
        metrics.invalidateHold()
        let snapshot = metrics.snapshot(state: "running", tapEnabled: true, now: DispatchTime.now().uptimeNanoseconds)
        XCTAssertEqual(snapshot.counters["holdGrants"], 2)
        XCTAssertEqual(snapshot.counters["holdInvalidations"], 1)
        XCTAssertEqual(snapshot.counters["heldEvents"], 3)
        XCTAssertEqual(snapshot.counters["releasedEvents"], 3)
        XCTAssertEqual(snapshot.counters["holdRefusals"], 1)
    }

    func testSnapshotJSONOnlyContainsAggregateSchema() throws {
        let metrics = EventTapMetrics(startedAt: 0)
        metrics.increment(.recoveryAttempts)
        metrics.increment(.recoverySuccesses)
        let snapshot = metrics.snapshot(state: "running", tapEnabled: true, now: 500)
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set([
            "instanceID", "uptimeSeconds", "state", "tapEnabled", "callbackCount", "eventCount",
            "maximumCallbackNanoseconds",
            "callbacksOverOneMillisecond", "histogramUpperBoundsNanoseconds", "histogramCounts", "counters"
        ]))
        XCTAssertEqual(snapshot.counters["recoveryAttempts"], 1)
        XCTAssertEqual(snapshot.counters["recoverySuccesses"], 1)
        XCTAssertEqual(Set(snapshot.counters.keys), Set(EventTapMetrics.Counter.allCases.map(\.rawValue)))
    }

    @MainActor
    func testDiagnosticsAreOptInAndStoppedTapCannotBeForceDisabled() async {
        let tap = EventTapCore { _ in }
        XCTAssertNil(tap.diagnosticsSnapshot())
        XCTAssertFalse(tap.disableTapForDiagnostics())
        tap.enableDiagnostics()
        XCTAssertEqual(tap.diagnosticsSnapshot()?.state, "stopped")
        XCTAssertFalse(tap.disableTapForDiagnostics())
        XCTAssertEqual(tap.diagnosticsSnapshot()?.counters["forcedDisables"], 0)
    }
}

final class EventTapRecoveryIntegrationTests: XCTestCase {
    @MainActor
    func testRealDisabledTapRecoversAndReceivesExternalKeyUp() async throws {
        guard CGPreflightListenEventAccess(), CGPreflightPostEventAccess() else {
            throw XCTSkip("Нет разрешений для настоящей доставки keyUp и recovery")
        }
        let baseline = XCTestExpectation(description: "Внешний keyUp до отключения")
        let recovered = XCTestExpectation(description: "Внешний keyUp после восстановления")
        let collector = RecoveryKeyUps()
        let tap = EventTapCore { raw in
            if let index = collector.record(raw) {
                if index == 0 { baseline.fulfill() } else { recovered.fulfill() }
            }
        }
        var recoveryBoundaries: [UInt64] = []
        tap.onRecoveryStarted = { [weak tap] timestamp in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(tap?.state, .recovering)
            XCTAssertEqual(tap?.diagnosticsSnapshot()?.tapEnabled, false, "Контекст сбрасывается до re-enable")
            recoveryBoundaries.append(timestamp)
        }
        tap.enableDiagnostics()
        guard tap.start() else { throw XCTSkip("Tap не создан; recovery не проверен") }
        defer { tap.stop() }
        try postExternalKeyUp(index: 0, collector: collector)
        let baselineResult = await XCTWaiter().fulfillment(of: [baseline], timeout: 5)
        guard baselineResult == .completed else {
            throw XCTSkip("Нет исходной доставки внешнего keyUp; recovery не проверен")
        }
        XCTAssertTrue(tap.disableTapForDiagnostics(), "Должен быть отключён настоящий CGEventTap")
        XCTAssertEqual(tap.diagnosticsSnapshot()?.tapEnabled, false)
        let deadline = Date().addingTimeInterval(4)
        while tap.diagnosticsSnapshot()?.tapEnabled != true, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let snapshot = try XCTUnwrap(tap.diagnosticsSnapshot())
        XCTAssertTrue(snapshot.tapEnabled, "Штатный health-check обязан восстановить тихо отключённый tap")
        XCTAssertEqual(snapshot.state, "running")
        XCTAssertGreaterThanOrEqual(snapshot.counters["recoverySuccesses"] ?? 0, 1)
        XCTAssertEqual(snapshot.counters["forcedDisables"], 1)
        XCTAssertEqual(recoveryBoundaries.count, 1)
        try postExternalKeyUp(index: 1, collector: collector)
        let recoveryResult = await XCTWaiter().fulfillment(of: [recovered], timeout: 5)
        XCTAssertEqual(recoveryResult, .completed, "После исходной доставки ошибка восстановления не является skip")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(collector.counts, [1, 1], "Внешний keyUp доставляется ровно один раз")
        XCTAssertTrue(collector.onlyExternalKeyUps)
        try await assertStoppedTapStaysStopped(tap)
    }

    @MainActor
    private func assertStoppedTapStaysStopped(_ tap: EventTapCore) async throws {
        tap.stop()
        let stoppedRecoveryCount = tap.recoveryCount
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(tap.state, .stopped)
        XCTAssertEqual(tap.recoveryCount, stoppedRecoveryCount, "Watchdog не должен оживлять остановленный tap")
        XCTAssertEqual(tap.diagnosticsSnapshot()?.tapEnabled, false)
    }

    private func postExternalKeyUp(index: Int, collector: RecoveryKeyUps) throws {
        // Никаких keyDown: тест не вводит символы и не вызывает команды активного приложения.
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x21, keyDown: false))
        event.flags = []
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        XCTAssertFalse(SyntheticEventMarker.isSynthetic(event))
        collector.expect(index: index, timestamp: event.timestamp)
        event.post(tap: .cghidEventTap)
    }
}

private final class RecoveryKeyUps: @unchecked Sendable {
    private let lock = NSLock()
    private var expected: [UInt64: Int] = [:]
    private var received: [[RawKeyEvent]] = [[], []]

    func expect(index: Int, timestamp: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        expected[timestamp] = index
    }

    func record(_ raw: RawKeyEvent) -> Int? {
        guard raw.type == .keyUp, raw.keyCode == 0x21 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let index = expected[raw.timestamp] else { return nil }
        let first = received[index].isEmpty
        received[index].append(raw)
        return first ? index : nil
    }

    var counts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return received.map(\.count)
    }

    var onlyExternalKeyUps: Bool {
        lock.lock()
        defer { lock.unlock() }
        return received.flatMap { $0 }.allSatisfy { $0.type == .keyUp && !$0.isSynthetic }
    }
}
#endif
