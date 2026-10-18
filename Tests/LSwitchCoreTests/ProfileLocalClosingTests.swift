#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class ProfileClosingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    func increment() { lock.lock(); reads += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return reads }
}

final class ProfileLocalClosingTests: XCTestCase {
    @MainActor
    func testLogicalClosingDoesNotCallInjectedClockAndChecksExactLeaseDeadline() throws {
        let fixture = try RecipientOrdinaryFixture()
        let state = EventProcessingLeaseState()
        let scope = fixture.capture.scope.binding.scope
        let lease = try XCTUnwrap(state.begin(scope: scope, at: 1))
        let counter = ProfileClosingCounter()
        let prepared = try XCTUnwrap(PreparedEventProcessingArm(state: state, lease: lease, clock: {
            counter.increment()
            return 1
        }))
        XCTAssertTrue(state.arm(lease, at: 1))
        let initialReads = counter.value
        XCTAssertTrue(prepared.isCurrent(at: 2))
        XCTAssertTrue(prepared.isCurrent(at: prepared.deadline - 1))
        XCTAssertFalse(prepared.isCurrent(at: prepared.deadline))
        XCTAssertFalse(prepared.isCurrent(at: 2), "Истечение необратимо для этой lease")
        XCTAssertEqual(counter.value, initialReads)
    }

    @MainActor
    func testLogicalClosingRejectsReplacedLeaseEvenWhenScopeAndClockMatch() throws {
        let fixture = try AtomicProcessingArmFixture()
        XCTAssertTrue(fixture.state.arm(fixture.lease, at: 0))
        XCTAssertTrue(fixture.state.claimFinish(fixture.lease, disposition: .discard, at: 1))
        _ = fixture.state.next(fixture.lease, at: 1)
        let replacement = try XCTUnwrap(fixture.state.begin(scope: fixture.lease.scope, at: 0))
        XCTAssertTrue(fixture.state.arm(replacement, at: 1))
        XCTAssertFalse(fixture.prepared.isCurrent(at: 1))
        XCTAssertTrue(fixture.state.isCurrent(replacement, at: 1))
    }

    @MainActor
    func testAdmissionAndPortClosingNeverInvokeGateCallback() throws {
        let counter = ProfileClosingCounter()
        let ledger = ConversionSafetyLedger(generation: 1)
        let target = try XCTUnwrap(RecoveryProcessIdentity(processID: 100, birthSeconds: 1, birthMicroseconds: 0))
        let scope = RecoveryOperationTarget(operation: ledger.operation, target: target)
        let admission = PreparedRecoveryAdmission(scope: scope, gate: .init(scope: scope, isCurrent: {
            counter.increment()
            return true
        }))
        let operation = try XCTUnwrap(RecoveryOperation.prepare(
            ledger: ledger, admission: admission, tapIdentifier: UUID(), at: 0,
            handoverFactory: .init(prepare: { scope, tap in
                .init(operationScope: scope, tapIdentifier: tap, protecting: { _, body in body() })
            })
        ))
        let port = operation.capturePort
        let initialReads = counter.value
        XCTAssertTrue(admission.isLocallyOpen(for: port.scope.binding))
        XCTAssertTrue(port.isLocallyOpen(for: port.scope, at: 1))
        let foreign = RecoveryCaptureScope(binding: port.scope.binding, tapIdentifier: UUID())
        XCTAssertFalse(port.isLocallyOpen(for: foreign, at: 1))
        admission.stop(.interceptionStopped)
        XCTAssertFalse(port.isLocallyOpen(for: port.scope, at: 1))
        XCTAssertEqual(counter.value, initialReads)
    }

    @MainActor
    func testNativeClosingUsesSuppliedTimeWithoutAttachmentClockAndExpiresOriginalDeadline() throws {
        let fixture = try RecipientOrdinaryFixture(startedAt: 10)
        fixture.clock.set(UInt64.max)
        XCTAssertTrue(fixture.capture.isCurrentLocally(at: 11), "Injected clock не вызывается")
        XCTAssertTrue(fixture.capture.isCurrentLocally(at: fixture.operation.capturePort.holdDeadline - 1))
        XCTAssertFalse(fixture.capture.isCurrentLocally(at: fixture.operation.capturePort.holdDeadline))
        XCTAssertFalse(fixture.capture.isCurrentLocally(at: 11))
        XCTAssertEqual(fixture.attachment.counters.payloadCountReads, 0)
    }

    @MainActor
    func testNativeClosingNeedsPublishedStateAndRejectsGateLossOrClosedGeneration() throws {
        let unpublished = try RecipientOrdinaryFixture(arm: false)
        XCTAssertFalse(unpublished.capture.isCurrentLocally(at: 1))
        let lost = try RecipientOrdinaryFixture()
        XCTAssertTrue(lost.capture.isCurrentLocally(at: 1))
        lost.state.markLost(.stopped)
        XCTAssertFalse(lost.capture.isCurrentLocally(at: 1))
        let closed = try RecipientOrdinaryFixture()
        closed.bridge.closeGeneration()
        XCTAssertFalse(closed.capture.isCurrentLocally(at: 1))
    }

    @MainActor
    func testNativeClosingObservesAdmissionOffAndPermissionLatchesEvenWithHealthyDriver() throws {
        let disabled = try RecipientOrdinaryFixture()
        disabled.coordinator.setEnabled(false)
        XCTAssertFalse(disabled.capture.isCurrentLocally(at: 1))
        disabled.coordinator.setEnabled(true)
        XCTAssertFalse(disabled.capture.isCurrentLocally(at: 1))
        let permissions = try RecipientOrdinaryFixture()
        permissions.coordinator.permissionsLost()
        XCTAssertFalse(permissions.capture.isCurrentLocally(at: 1))
    }
}
#endif
