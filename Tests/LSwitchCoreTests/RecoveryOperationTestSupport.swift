import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

/// Тестовый guard держит один lock для admission readiness и protected detach, как будущий системный адаптер.
final class RecoveryCaptureTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let control = NSLock()
    private var available = true
    private var scope: RecoveryCaptureScope?
    private var pauseAdmission = false
    let admissionEntered = DispatchSemaphore(value: 0)
    let continueAdmission = DispatchSemaphore(value: 0)
    let protectionEntered = DispatchSemaphore(value: 0)

    func bind(_ scope: RecoveryCaptureScope) {
        lock.lock()
        self.scope = scope
        lock.unlock()
    }

    func setAvailable(_ value: Bool) {
        lock.lock()
        available = value
        lock.unlock()
    }

    func pauseNextAdmission() {
        control.lock()
        pauseAdmission = true
        control.unlock()
    }

    func isCurrent() -> Bool {
        control.lock()
        let shouldPause = pauseAdmission
        pauseAdmission = false
        control.unlock()
        if shouldPause {
            admissionEntered.signal()
            guard continueAdmission.wait(timeout: .now() + 3) == .success else { return false }
        }
        guard lock.lock(before: Date().addingTimeInterval(2)) else { return false }
        defer { lock.unlock() }
        return available
    }

    func protect(_ expected: RecoveryCaptureScope, body: () -> Void) {
        guard lock.lock(before: Date().addingTimeInterval(2)) else { return }
        defer { lock.unlock() }
        protectionEntered.signal()
        guard available, scope == expected else { return }
        body()
    }

    func prepared(_ scope: RecoveryOperationTarget, tap: UUID) -> PreparedRecoveryHandover {
        PreparedRecoveryHandover(operationScope: scope, tapIdentifier: tap, protecting: { self.protect($0, body: $1) })
    }
}

@MainActor
final class RecoveryOperationFixture {
    let gate: RecoveryCaptureTestGate
    let ledger: ConversionSafetyLedger
    let coordinator: RecoveryCoordinator
    let admission: PreparedRecoveryAdmission
    let operation: RecoveryOperation

    init() throws {
        let gate = RecoveryCaptureTestGate()
        self.gate = gate
        let ledger = ConversionSafetyLedger(generation: 1)
        self.ledger = ledger
        let coordinator = RecoveryCoordinator(gateFactory: .init(prepare: { scope in
            .init(scope: scope, isCurrent: { gate.isCurrent() })
        }))
        self.coordinator = coordinator
        let target = try XCTUnwrap(RecoveryProcessIdentity(processID: 123, birthSeconds: 1, birthMicroseconds: 2))
        let admission = try XCTUnwrap(coordinator.reserve(operation: ledger.operation, target: target))
        self.admission = admission
        let operation = try XCTUnwrap(RecoveryOperation.prepare(
            ledger: ledger, admission: admission, tapIdentifier: UUID(), at: 0,
            handoverFactory: .init(prepare: { gate.prepared($0, tap: $1) })
        ))
        self.operation = operation
        gate.bind(operation.capturePort.scope)
    }

    func append(_ text: String = "a", at now: UInt64 = 1) throws -> RecoveryEventAdmission {
        let port = operation.capturePort
        return port.capture(try Self.event(text), utf16Units: text.utf16.count, from: port.scope, at: now)
    }

    func finishRecovery() {
        XCTAssertNotNil(ledger.finishUsingRecordedCleanup(
            operation: ledger.operation, text: .unknown, ordinaryRouteValid: false
        ))
    }

    func revealedTexts() throws -> [String] {
        let intent = try XCTUnwrap(coordinator.requestReveal())
        XCTAssertTrue(coordinator.reveal(intent))
        return try XCTUnwrap(coordinator.revealedProjection).entries.compactMap {
            guard case .unicodeFragment(let fragment) = $0.content else { return nil }
            return fragment.text
        }
    }

    nonisolated static func event(_ text: String) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        event.flags = []
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        let units = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        return event
    }
}

/// Имитирует только lifetime владельца tap; системный tap и доставка здесь отсутствуют.
final class RecoveryTestTapOwner {
    let port: RecoveryCapturePort

    init(port: RecoveryCapturePort) { self.port = port }

    deinit { port.invalidate(.interceptionStopped, scope: port.scope) }
}
