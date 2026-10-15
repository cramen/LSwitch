#if DEBUG
import Dispatch
import Foundation

/// Только агрегированные metadata: содержимое и идентификаторы событий сюда не передаются.
public struct EventTapDiagnosticsSnapshot: Codable, Sendable {
    public let instanceID: String
    public let uptimeSeconds: Double
    public let state: String
    public let tapEnabled: Bool
    public let callbackCount: UInt64
    public let eventCount: UInt64
    public let maximumCallbackNanoseconds: UInt64
    public let callbacksOverOneMillisecond: UInt64
    public let histogramUpperBoundsNanoseconds: [UInt64]
    public let histogramCounts: [UInt64]
    public let p99UpperBoundNanoseconds: UInt64?
    public let counters: [String: UInt64]
}

final class EventTapMetrics: @unchecked Sendable {
    enum Counter: String, CaseIterable {
        case starts, stops, recoveryAttempts, recoverySuccesses, recoveryFailures
        case silentDisableDetections, timeoutNotifications, userDisableNotifications
        case wakeNotifications, sessionNotifications, forcedDisables
        case holdGrants, holdRefusals, heldEvents, releasedEvents, holdInvalidations
    }

    static let bounds: [UInt64] = [10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_000_000, 5_000_000]
    private let lock = NSLock()
    private let instanceID = UUID().uuidString
    private let startedAt: UInt64
    private var callbackCount: UInt64 = 0
    private var maximumDuration: UInt64 = 0
    private var overBudget: UInt64 = 0
    private var histogram = [UInt64](repeating: 0, count: EventTapMetrics.bounds.count + 1)
    private var counters = Dictionary(uniqueKeysWithValues: Counter.allCases.map { ($0.rawValue, UInt64(0)) })
    private var trackedHoldValid = false

    init(startedAt: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.startedAt = startedAt
    }

    /// Измерение включает ожидание замка метрик, но не запись нескольких счётчиков после timestamp.
    func recordCallback(startedAt: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        let finishedAt = DispatchTime.now().uptimeNanoseconds
        recordDuration(finishedAt >= startedAt ? finishedAt - startedAt : 0)
    }

    /// Чистый вход для проверки границ гистограммы без системных событий.
    func recordCallback(durationNanoseconds: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        recordDuration(durationNanoseconds)
    }

    func increment(_ counter: Counter, by count: UInt64 = 1) {
        lock.lock()
        defer { lock.unlock() }
        counters[counter.rawValue, default: 0] += count
        if counter == .holdGrants { trackedHoldValid = true }
    }

    func invalidateHold() {
        lock.lock()
        defer { lock.unlock() }
        guard trackedHoldValid else { return }
        counters[Counter.holdInvalidations.rawValue, default: 0] += 1
        trackedHoldValid = false
    }

    func finishHold(released: Int) {
        lock.lock()
        defer { lock.unlock() }
        counters[Counter.releasedEvents.rawValue, default: 0] += UInt64(released)
        trackedHoldValid = false
    }

    func snapshot(state: String, tapEnabled: Bool, now: UInt64) -> EventTapDiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let notifications = counters[Counter.timeoutNotifications.rawValue, default: 0]
            + counters[Counter.userDisableNotifications.rawValue, default: 0]
        return EventTapDiagnosticsSnapshot(
            instanceID: instanceID,
            uptimeSeconds: Double(now >= startedAt ? now - startedAt : 0) / 1_000_000_000,
            state: state, tapEnabled: tapEnabled, callbackCount: callbackCount,
            eventCount: callbackCount >= notifications ? callbackCount - notifications : 0,
            maximumCallbackNanoseconds: maximumDuration, callbacksOverOneMillisecond: overBudget,
            histogramUpperBoundsNanoseconds: Self.bounds, histogramCounts: histogram,
            p99UpperBoundNanoseconds: percentileUpperBound(), counters: counters
        )
    }

    private func recordDuration(_ duration: UInt64) {
        callbackCount += 1
        maximumDuration = max(maximumDuration, duration)
        if duration > 1_000_000 { overBudget += 1 }
        let index = Self.bounds.firstIndex { duration <= $0 } ?? Self.bounds.count
        histogram[index] += 1
    }

    private func percentileUpperBound() -> UInt64? {
        guard callbackCount > 0 else { return nil }
        let rank = callbackCount - callbackCount / 100
        var cumulative: UInt64 = 0
        for (index, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= rank { return index < Self.bounds.count ? Self.bounds[index] : nil }
        }
        return nil
    }
}
#endif
