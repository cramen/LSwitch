import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true
    private var prepared = 0

    func setAvailable(_ available: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.available = available
    }

    func isCurrent() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    var preparationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return prepared
    }

    func prepare(_ scope: RecoveryOperationTarget) -> RecoveryGateCapability {
        lock.lock()
        prepared += 1
        lock.unlock()
        return RecoveryGateCapability(scope: scope, isCurrent: { self.isCurrent() })
    }
}

struct RecoveryTestHold {
    let admission: PreparedRecoveryAdmission
    let binding: RecoveryHoldBinding
    let buffer: InputEventBuffer

    func append(_ text: String = "a", type: CGEventType = .keyDown) throws -> RecoveryEventAdmission {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: type == .keyDown))
        event.type = type
        event.flags = []
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        let units = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        return admission.admit(utf16Units: units.count, binding: binding) {
            buffer.intercept(type: type, event: event, at: 1)
        }
    }

    func handover() throws -> (sealed: RecoveryAdmissionSeal, batch: HeldInputBatch) {
        let sealed = try XCTUnwrap(admission.seal(binding: binding))
        let batch = try XCTUnwrap(buffer.detach(token: binding.hold))
        return (sealed, batch)
    }
}

@MainActor
final class RecoveryTestFixture {
    let gate: RecoveryTestGate
    let ledger = ConversionSafetyLedger(generation: 1)
    let target: RecoveryProcessIdentity
    let coordinator: RecoveryCoordinator

    init(eventReader: RecoveryEventReader? = nil) throws {
        let gate = RecoveryTestGate()
        self.gate = gate
        target = try XCTUnwrap(RecoveryProcessIdentity(processID: 123, birthSeconds: 1, birthMicroseconds: 2))
        coordinator = RecoveryCoordinator(
            gateFactory: RecoveryGateFactory(prepare: { gate.prepare($0) }), eventReader: eventReader
        )
    }

    func begin() throws -> RecoveryTestHold {
        let admission = try XCTUnwrap(coordinator.reserve(operation: ledger.operation, target: target))
        let buffer = InputEventBuffer()
        let token = try XCTUnwrap(buffer.beginHold(at: 0))
        let binding = try XCTUnwrap(admission.bindHold(token))
        return RecoveryTestHold(admission: admission, binding: binding, buffer: buffer)
    }

    func claim(recovery: Bool = true) throws -> ConversionSafetyInputClaim {
        if recovery {
            let submitted = try XCTUnwrap(ledger.willSubmit(.selection, operation: ledger.operation))
            XCTAssertTrue(ledger.observe(.unknown, for: submitted))
        }
        XCTAssertNotNil(ledger.finish(
            operation: ledger.operation, text: .unchangedByOperation,
            cleanup: recovery ? .recoveryUnconfirmed : .noOwnedMutation, ordinaryRouteValid: !recovery
        ))
        return try XCTUnwrap(ledger.claimInput(operation: ledger.operation))
    }

    @discardableResult
    func adopt(_ hold: RecoveryTestHold) throws -> UUID {
        let transfer = try hold.handover()
        let result = coordinator.adopt(transfer.batch, sealed: transfer.sealed,
                                       claim: try claim(), reason: .cleanupUnconfirmed)
        guard case .adopted(let identifier) = result else {
            XCTFail("Подготовленный RAM handover должен принять очередь")
            throw RecoveryTestError.adoptionFailed
        }
        XCTAssertNil(transfer.batch.claim())
        return identifier
    }
}

enum RecoveryTestError: Error { case adoptionFailed }
