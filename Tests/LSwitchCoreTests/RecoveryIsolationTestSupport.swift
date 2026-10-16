#if DEBUG
import CoreGraphics
import Darwin
import Foundation
@testable import LSwitchCore
import XCTest

/// Только RAM-модель driver; не создаёт tap и не заявляет системную защиту.
final class RecoveryIsolationTestProtection: RecoveryIsolationProtecting, @unchecked Sendable {
    let bridge: RecoveryRecipientProbeBridge
    private let lock = NSLock()
    private var available = true
    @MainActor var onRefresh: () -> Void = {}

    init(bridge: RecoveryRecipientProbeBridge) { self.bridge = bridge }

    var isProtectionAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return available && bridge.isProtectionAvailable
    }

    var permitsMutation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return available && bridge.permitsMutation
    }

    @MainActor
    func refreshProtection() -> Bool {
        onRefresh()
        return isProtectionAvailable
    }

    func withProtection(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if available && bridge.isProtectionAvailable { body() }
    }

    func setAvailable(_ value: Bool) {
        lock.lock()
        available = value
        lock.unlock()
    }
}

@MainActor
final class RecoveryIsolationFixture {
    let session: RecoveryIsolationSession
    let protection: RecoveryIsolationTestProtection
    let router = RecoveryCaptureRouter(bypassRawProcessing: true)
    let markers: RecoveryIsolationFixtureMarkers
    let target: RecoveryProcessIdentity
    let sender: RecoveryProcessIdentity

    init(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) throws {
        let sender = try XCTUnwrap(RecoveryProcessIdentity(processID: getpid(), birthSeconds: 1, birthMicroseconds: 0))
        let target = try XCTUnwrap(RecoveryProcessIdentity(processID: Int32.max, birthSeconds: 2, birthMicroseconds: 0))
        let markers = try XCTUnwrap(RecoveryIsolationSession.allocateFixtureMarkers())
        self.sender = sender
        self.target = target
        self.markers = markers
        let session = try XCTUnwrap(RecoveryIsolationSession(
            sender: sender, target: target,
            filter: .init(senderProcessID: sender.processID,
                          downMarker: markers.prefixDown, releaseMarker: markers.prefixRelease),
            identityCheck: { _ in true }, clock: clock
        ))
        self.session = session
        protection = RecoveryIsolationTestProtection(bridge: session.bridge)
    }

    func prepare() {
        XCTAssertTrue(session.prepareCapture(router: router, protection: protection))
        XCTAssertTrue(session.beginFixtureSelectionCommand())
        session.markFixtureSelectionUnknown(commandReturned: true)
    }

    func tap(handler: @escaping EventTapCore.Handler = { _ in XCTFail("Diagnostic bypass не декодирует raw") })
        -> EventTapCore {
        EventTapCore(handler: handler, processingQueue: DispatchQueue(label: "test.isolation"),
                     recoveryCaptureRouter: router)
    }

    func prefix(_ text: String = "kept", down: Bool = true) throws -> CGEvent {
        try Self.event(text, marker: down ? markers.prefixDown : markers.prefixRelease, down: down)
    }

    static func event(_ text: String, marker: Int64, down: Bool = true) throws -> CGEvent {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down))
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        let units = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUnixProcessID), Int64(getpid()))
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), marker)
        return event
    }
}

final class RecoveryIsolationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1

    func read() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: UInt64) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}
#endif
