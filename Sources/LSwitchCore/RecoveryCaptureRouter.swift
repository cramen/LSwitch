import CoreGraphics
import Dispatch
import Foundation

enum RecoveryCaptureRoute: Equatable { case legacy, passThrough, suppress }

struct RecoveryFixtureCaptureFilter: Sendable {
    let senderProcessID: Int32
    let downMarker: Int64
    let releaseMarker: Int64

    func matches(type: CGEventType, sender: Int64, marker: Int64) -> Bool {
        guard sender == Int64(senderProcessID) else { return false }
        return (type == .keyDown && marker == downMarker) || (type == .keyUp && marker == releaseMarker)
    }
}

struct RecoveryCaptureCounters: Sendable {
    let capturedEvents: Int
    let capturedUTF16Bytes: Int
    let rejectedEvents: Int
    let payloadCountReads: Int
}

/// Endpoint не читает Unicode до проверки фиксированных fixture headers и действующего допуска.
final class RecoveryCaptureAttachment: @unchecked Sendable {
    let port: RecoveryCapturePort
    let filter: RecoveryFixtureCaptureFilter
    private let ownMarker: @Sendable (Int64, Int64) -> Bool
    private let clock: @Sendable () -> UInt64
    private let lock = NSLock()
    private var captured = 0
    private var bytes = 0
    private var rejected = 0
    private var reads = 0

    init(
        port: RecoveryCapturePort, filter: RecoveryFixtureCaptureFilter,
        ownMarker: @escaping @Sendable (Int64, Int64) -> Bool,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.port = port
        self.filter = filter
        self.ownMarker = ownMarker
        self.clock = clock
    }

    func route(type: CGEventType, event: CGEvent) -> RecoveryCaptureRoute {
        guard type == .keyDown || type == .keyUp else { return .passThrough }
        let marker = event.getIntegerValueField(.eventSourceUserData)
        let sender = event.getIntegerValueField(.eventSourceUnixProcessID)
        guard marker != SyntheticEventMarker.magic, !ownMarker(sender, marker),
              filter.matches(type: type, sender: sender, marker: marker) else { return .passThrough }
        let now = clock()
        port.expire(scope: port.scope, at: now)
        guard port.permitsMutation(for: port.scope) else { recordRejected(); return .suppress }
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
        let result = port.capture(event, utf16Units: count, from: port.scope, at: now)
        lock.lock()
        reads += 1
        switch result {
        case .accepted, .acceptedRequiringHandover:
            captured += 1
            bytes += count * 2
        case .rejected: rejected += 1
        }
        lock.unlock()
        return .suppress
    }

    func invalidate(_ reason: RecoveryAdmissionFailure) { port.invalidate(reason, scope: port.scope) }
    func expire() { port.expire(scope: port.scope, at: clock()) }

    var counters: RecoveryCaptureCounters {
        lock.lock()
        defer { lock.unlock() }
        return .init(capturedEvents: captured, capturedUTF16Bytes: bytes,
                     rejectedEvents: rejected, payloadCountReads: reads)
    }

    private func recordRejected() {
        lock.lock()
        rejected += 1
        lock.unlock()
    }
}

/// Diagnostic mode остаётся metadata-only после detach: чужие события не попадают в legacy raw decoder.
final class RecoveryCaptureRouter: @unchecked Sendable {
    let identifier = UUID()
    let bypassRawProcessing: Bool
    private let lock = NSLock()
    private var attachment: RecoveryCaptureAttachment?
    private var used = false

    init(bypassRawProcessing: Bool = false) { self.bypassRawProcessing = bypassRawProcessing }

    func attach(_ candidate: RecoveryCaptureAttachment) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard bypassRawProcessing, !used, candidate.port.scope.tapIdentifier == identifier else { return false }
        used = true
        attachment = candidate
        return true
    }

    func route(type: CGEventType, event: CGEvent) -> RecoveryCaptureRoute {
        lock.lock()
        let current = attachment
        lock.unlock()
        if let current { return current.route(type: type, event: event) }
        return bypassRawProcessing ? .passThrough : .legacy
    }

    @discardableResult
    func detach(_ expected: RecoveryCaptureAttachment) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard attachment === expected else { return false }
        attachment = nil
        return true
    }

    func invalidate(_ reason: RecoveryAdmissionFailure) {
        lock.lock()
        let current = attachment
        lock.unlock()
        current?.invalidate(reason)
    }
}
