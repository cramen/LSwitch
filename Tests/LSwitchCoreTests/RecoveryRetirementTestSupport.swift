#if DEBUG
import CoreGraphics
import Darwin
import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryRetirementBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let phase: RecoveryCapturePhase

    init(_ phase: RecoveryCapturePhase) { self.phase = phase }

    func observe(_ current: RecoveryCapturePhase) {
        guard current == phase else { return }
        entered.signal()
        XCTAssertEqual(proceed.wait(timeout: .now() + 3), .success)
    }
}

@MainActor
final class RecoveryRetirementFixture {
    let gate: RecoveryCaptureTestGate
    let ledger: ConversionSafetyLedger
    let coordinator: RecoveryCoordinator
    let operation: RecoveryOperation
    let router: RecoveryCaptureRouter
    let attachment: RecoveryCaptureAttachment

    init(observePhase: @escaping @Sendable (RecoveryCapturePhase) -> Void = { _ in }) throws {
        let gate = RecoveryCaptureTestGate()
        let ledger = ConversionSafetyLedger(generation: 1)
        let router = RecoveryCaptureRouter(bypassRawProcessing: true)
        let coordinator = RecoveryCoordinator(gateFactory: .init(prepare: { scope in
            RecoveryGateCapability(scope: scope, isCurrent: { gate.isCurrent() })
        }))
        let target = try XCTUnwrap(RecoveryProcessIdentity(processID: 123, birthSeconds: 1, birthMicroseconds: 2))
        let admission = try XCTUnwrap(coordinator.reserve(operation: ledger.operation, target: target))
        let operation = try XCTUnwrap(RecoveryOperation.prepare(
            ledger: ledger, admission: admission, tapIdentifier: router.identifier, at: 0,
            handoverFactory: .init(prepare: { gate.prepared($0, tap: $1) })
        ))
        gate.bind(operation.capturePort.scope)
        let attachment = RecoveryCaptureAttachment(
            port: operation.capturePort,
            filter: .init(senderProcessID: getpid(), downMarker: 1234, releaseMarker: 1235),
            ownMarker: { _, _ in false }, clock: { 1 }, observePhase: observePhase
        )
        XCTAssertTrue(router.attach(attachment))
        self.gate = gate
        self.ledger = ledger
        self.coordinator = coordinator
        self.operation = operation
        self.router = router
        self.attachment = attachment
    }

    func event() throws -> CGEvent { try RecoveryIsolationFixture.event("kept", marker: 1234) }

    func retiredProof() throws -> RecoveryRetiredCaptureProof {
        XCTAssertTrue(router.beginRetirement(attachment))
        let port = operation.capturePort
        let seal = try XCTUnwrap(port.trySealForStorage(scope: port.scope))
        return try XCTUnwrap(router.retiredProof(seal: seal))
    }

    func adopt() throws -> UUID {
        _ = ledger.finishUsingRecordedCleanup(operation: ledger.operation, text: .unknown, ordinaryRouteValid: false)
        guard case .adopted(let identifier) = operation.adopt(in: coordinator, reason: .cleanupUnconfirmed) else {
            XCTFail("RAM transfer должен завершиться после quiescence")
            throw NSError(domain: "RecoveryRetirementFixture", code: 1)
        }
        return identifier
    }
}
#endif
