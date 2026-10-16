#if DEBUG
import CoreGraphics
import Darwin
import Foundation
@testable import LSwitchCore
import XCTest

/// Настоящий lock driver-state включён в admission; системный worker/post не запускается.
final class RecipientCaptureProtection: RecoveryIsolationProtecting, @unchecked Sendable {
    let state: RecipientTapDriverState
    var bridge: RecoveryRecipientProbeBridge { state.bridge }
    var isProtectionAvailable: Bool { state.isProtectionAvailable }
    var permitsMutation: Bool { state.permitsMutation }

    init(state: RecipientTapDriverState) { self.state = state }
    @MainActor func refreshProtection() -> Bool { state.isProtectionAvailable }
    func withProtection(_ body: () -> Void) { state.withProtection(body) }
}

@MainActor
final class RecipientTapCaptureFixture {
    let session: RecoveryIsolationSession
    let state: RecipientTapDriverState
    let router = RecoveryCaptureRouter(bypassRawProcessing: true)
    let filter: RecoveryFixtureCaptureFilter
    let markers: RecoveryIsolationFixtureMarkers
    let clock: RecipientCaptureTestClock

    init(senderOverride: RecoveryProcessIdentity? = nil) throws {
        let sender = try XCTUnwrap(senderOverride ?? SystemProcessIdentity.read(processID: getpid()))
        let target = try XCTUnwrap(RecoveryProcessIdentity(processID: .max, birthSeconds: 99, birthMicroseconds: 0))
        let markers = try XCTUnwrap(RecoveryIsolationSession.allocateFixtureMarkers())
        self.markers = markers
        let filter = RecoveryFixtureCaptureFilter(senderProcessID: sender.processID,
                                                  downMarker: markers.prefixDown, releaseMarker: markers.prefixRelease)
        self.filter = filter
        let clock = RecipientCaptureTestClock()
        self.clock = clock
        let session = try XCTUnwrap(RecoveryIsolationSession(
            sender: sender, target: target, filter: filter, identityCheck: { _ in true }, clock: { clock.read() }
        ))
        self.session = session
        let state = RecipientTapDriverState(bridge: session.bridge)
        self.state = state
        state.recordInstallation(head: true, tail: true)
        XCTAssertTrue(session.prepareCapture(router: router, protection: RecipientCaptureProtection(state: state)))
        XCTAssertTrue(state.captureEndpoint.bind(router: router, filter: filter, scope: session.bridge.capturedScope))
    }

    func event(down: Bool = true) throws -> CGEvent {
        try RecoveryIsolationFixture.event(
            "kept", marker: down ? markers.prefixDown : markers.prefixRelease, down: down
        )
    }
}

/// Останавливает callback до admission, чтобы завершить detach конкурентно без системного ввода.
final class RecipientCaptureTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1
    private var pause = false
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)

    func read() -> UInt64 {
        lock.lock()
        let shouldPause = pause
        pause = false
        let result = value
        lock.unlock()
        if shouldPause {
            entered.signal()
            _ = proceed.wait(timeout: .now() + 3)
        }
        return result
    }

    func pauseNextRead() { lock.lock(); pause = true; lock.unlock() }
    func set(_ value: UInt64) { lock.lock(); self.value = value; lock.unlock() }
}
#endif
