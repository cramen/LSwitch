import CoreGraphics
import Foundation

/// Только логический дубликат RawKeyEvent; ни одного CGEvent, native post или recovery claim.
/// Локальные bounded getters выполняются под lock, поэтому invalidation не оставляет поздних payload reads.
final class EventProcessingLeaseState: @unchecked Sendable {
    static let maximumEvents = 256
    static let maximumUTF16Bytes = 65_536
    static let duration: UInt64 = 400_000_000
    private let lock = NSLock()
    private let identity = UUID()
    private let eventLimit: Int
    private let byteLimit: Int
    private var epoch: UInt64 = 0
    private var activity: UInt64 = 0
    private var current: Record?

    init(eventLimit: Int = maximumEvents, byteLimit: Int = maximumUTF16Bytes) {
        self.eventLimit = max(0, min(eventLimit, Self.maximumEvents))
        self.byteLimit = max(0, min(byteLimit, Self.maximumUTF16Bytes))
    }

    var hasLease: Bool {
        lock.lock()
        defer { lock.unlock() }
        return current != nil
    }

    private final class Record {
        let lease: EventProcessingLease
        let initialActivity: UInt64
        let deadline: UInt64
        var armed = false
        var finishing = false
        var failure: EventProcessingInvalidation?
        var events: [RawKeyEvent] = []
        var cursor = 0
        var bytes = 0
        var reads = 0
        var disposition = EventProcessingDisposition.discard

        init(lease: EventProcessingLease, activity: UInt64, deadline: UInt64) {
            self.lease = lease
            initialActivity = activity
            self.deadline = deadline
        }
    }

    func begin(scope: RecoveryOperationTarget, at now: UInt64) -> EventProcessingLease? {
        lock.lock()
        defer { lock.unlock() }
        guard current == nil, epoch < UInt64.max, now <= UInt64.max - Self.duration else { return nil }
        epoch += 1
        let lease = EventProcessingLease(scope: scope, epoch: epoch, stateIdentity: identity)
        current = Record(lease: lease, activity: activity, deadline: now + Self.duration)
        return lease
    }

    /// Вызывается синхронно из callback до любой async очереди. true означает только skip logical processing.
    func observe(type: CGEventType, event: CGEvent, at now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isActivity(type), !SyntheticEventMarker.isSynthetic(event) else { return current != nil }
        if activity < UInt64.max { activity += 1 }
        guard let current else { return false }
        expire(current, at: now)
        guard current.failure == nil else { return true }
        guard current.armed else { invalidate(current, reason: .inputBeforeCapture); return true }
        guard current.events.count < eventLimit else { invalidate(current, reason: .eventLimit); return true }
        let result = EventProcessingRawReader.read(
            type: type, event: event, remainingUnits: (byteLimit - current.bytes) / 2
        )
        record(result, in: current)
        return true
    }

    private func record(_ result: EventProcessingRawReader.Result, in current: Record) {
        switch result {
        case .event(let raw, let units, let payloadRead):
            current.events.append(raw)
            current.bytes += units * 2
            if payloadRead { current.reads += 1 }
        case .failure(let reason, let payloadRead):
            if payloadRead { current.reads += 1 }
            invalidate(current, reason: reason)
        }
    }

    func preCaptureReady(_ lease: EventProcessingLease, at now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current, current.lease == lease else { return false }
        expire(current, at: now)
        return mayArm(current)
    }

    /// После synchronous native activation проверяется тот же counter: reentry не превращается в допуск.
    func arm(_ lease: EventProcessingLease, at now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current, current.lease == lease else { return false }
        expire(current, at: now)
        guard mayArm(current) else { return false }
        current.armed = true
        return true
    }

    #if DEBUG
    func preparationDeadline(_ lease: EventProcessingLease, at now: UInt64) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard let current, current.lease == lease else { return nil }
        expire(current, at: now)
        return mayArm(current) ? current.deadline : nil
    }

    /// Lock закрывает interval между logical arm и native publish для глобального callback.
    func armPublishing(
        _ lease: EventProcessingLease, at now: UInt64, publication: RecipientCapturePublication
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current, current.lease == lease, publication.capture.scope.binding.scope == lease.scope,
              publication.capture.attachment.port.holdDeadline <= current.deadline else {
            return false
        }
        expire(current, at: now)
        guard mayArm(current) else { return false }
        guard publication.publish() else { invalidate(current, reason: .captureRefused); return false }
        current.armed = true
        return true
    }
    #endif

    func isCurrent(_ lease: EventProcessingLease, at now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current, current.lease == lease else { return false }
        expire(current, at: now)
        return current.armed && current.failure == nil && !current.finishing
    }

    func invalidate(_ reason: EventProcessingInvalidation, lease: EventProcessingLease? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let current, lease == nil || current.lease == lease else { return }
        invalidate(current, reason: reason)
    }

    func expire(_ lease: EventProcessingLease, at now: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let current, current.lease == lease else { return }
        expire(current, at: now)
    }

    func claimFinish(_ lease: EventProcessingLease, disposition: EventProcessingDisposition, at now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let current, current.lease == lease, !current.finishing else { return false }
        expire(current, at: now)
        current.finishing = true
        current.disposition = disposition
        return true
    }

    /// FIFO и переход в normal неделимы для callback; новый handler возможен только после последнего tail.
    func next(_ lease: EventProcessingLease, at now: UInt64) -> EventProcessingStep {
        lock.lock()
        defer { lock.unlock() }
        guard let current, current.lease == lease, current.finishing else { return .finished(.stale) }
        expire(current, at: now)
        if let failure = current.failure { self.current = nil; return .finished(.reset(failure)) }
        guard case .delivered(let correction) = current.disposition else {
            self.current = nil
            return .finished(.discarded)
        }
        guard current.armed else {
            self.current = nil
            return .finished(.reset(.captureRefused))
        }
        guard current.cursor < current.events.count else { self.current = nil; return .finished(.delivered) }
        let raw = current.events[current.cursor]
        current.cursor += 1
        return .event(correction?.correctedTracked(raw) ?? raw)
    }

    var metadata: EventProcessingMetadata {
        lock.lock()
        defer { lock.unlock() }
        return .init(activity: activity, eventCount: current?.events.count ?? 0,
                     utf16Bytes: current?.bytes ?? 0, payloadReads: current?.reads ?? 0,
                     armed: current?.armed ?? false, failure: current?.failure)
    }

    /// Только сохранённая причина exact lease; чтение отчёта само не продлевает и не истекает lease.
    func failure(for lease: EventProcessingLease) -> EventProcessingInvalidation? {
        lock.lock()
        defer { lock.unlock() }
        guard current?.lease == lease else { return nil }
        return current?.failure
    }

    private func expire(_ record: Record, at now: UInt64) {
        if now >= record.deadline { invalidate(record, reason: .expired) }
    }

    private func mayArm(_ record: Record) -> Bool {
        !record.armed && !record.finishing && record.failure == nil
            && activity == record.initialActivity && activity < UInt64.max
    }

    private func invalidate(_ record: Record, reason: EventProcessingInvalidation) {
        record.failure = record.failure ?? reason
        record.events.removeAll()
        record.bytes = 0
        record.cursor = 0
    }

    private static func isActivity(_ type: CGEventType) -> Bool {
        switch type {
        case .keyDown, .keyUp, .flagsChanged,
             .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel: return true
        default: return false
        }
    }
}
