#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryRetirementTests: XCTestCase {
    @MainActor
    func testLossAfterProtectedDetachRetiresAndAdoptsTheSamePrivateBatch() throws {
        let fixture = try RecoveryRetirementFixture()
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: try fixture.event()), .suppress)
        XCTAssertEqual(fixture.operation.closeCapture(), .detached(.init(events: 1, utf16Bytes: 8)))
        fixture.gate.setAvailable(false)
        XCTAssertTrue(fixture.operation.closeCaptureForStorage(router: fixture.router, attachment: fixture.attachment))
        _ = try fixture.adopt()
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
        let intent = try XCTUnwrap(fixture.coordinator.requestReveal())
        XCTAssertTrue(fixture.coordinator.reveal(intent))
        XCTAssertEqual(fixture.coordinator.revealedProjection?.entries.first?.content,
                       .unicodeFragment(.init(text: "kept")))
        XCTAssertTrue(fixture.operation.closeCaptureForStorage(router: fixture.router, attachment: fixture.attachment))
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
    }

    @MainActor
    func testLossBeforeAdoptTransfersAcceptedEventsWithoutUsingProtection() throws {
        let fixture = try RecoveryRetirementFixture()
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: try fixture.event()), .suppress)
        fixture.gate.setAvailable(false)
        XCTAssertEqual(fixture.operation.closeCapture(), .awaitingProtection(.init(events: 1, utf16Bytes: 8)))
        XCTAssertTrue(fixture.operation.closeCaptureForStorage(router: fixture.router, attachment: fixture.attachment))
        XCTAssertEqual(fixture.gate.protectionEntered.wait(timeout: .now()), .success, "Только прежний close")
        XCTAssertEqual(fixture.gate.protectionEntered.wait(timeout: .now()), .timedOut, "Storage не вызывает gate")
        let identifier = try fixture.adopt()
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
        XCTAssertTrue(fixture.operation.closeCaptureForStorage(router: fixture.router, attachment: fixture.attachment))
        XCTAssertEqual(fixture.operation.adopt(in: fixture.coordinator, reason: .cleanupUnconfirmed),
                       .adopted(identifier))
        XCTAssertNil(fixture.ledger.willSubmit(.text, operation: fixture.ledger.operation))
    }

    @MainActor
    func testRetirementIsIrreversibleAndLateHeadersNeverReadPayload() throws {
        let fixture = try RecoveryRetirementFixture()
        XCTAssertTrue(fixture.router.beginRetirement(fixture.attachment))
        XCTAssertFalse(fixture.router.matchesCapture(
            scope: fixture.operation.capturePort.scope.binding.scope, filter: fixture.attachment.filter
        ))
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: try fixture.event()), .suppress)
        XCTAssertEqual(fixture.router.route(type: .keyUp, event: try fixture.event()), .suppress)
        XCTAssertEqual(fixture.attachment.counters.payloadCountReads, 0)
        XCTAssertEqual(fixture.attachment.counters.capturedEvents, 0)
        XCTAssertTrue(fixture.operation.closeCaptureForStorage(router: fixture.router, attachment: fixture.attachment))
        XCTAssertFalse(fixture.router.attach(fixture.attachment))
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: try fixture.event()), .suppress)
        XCTAssertEqual(fixture.attachment.counters.payloadCountReads, 0)
    }

    @MainActor
    func testProofRequiresRetirementAndConcretePortSealThenCanBeConsumedOnlyOnce() throws {
        let fixture = try RecoveryRetirementFixture()
        let port = fixture.operation.capturePort
        let seal = try XCTUnwrap(port.trySealForStorage(scope: port.scope))
        XCTAssertNil(fixture.router.retiredProof(seal: seal))
        XCTAssertTrue(fixture.router.beginRetirement(fixture.attachment))
        let scope = port.scope.binding.scope
        let differentAdmission = PreparedRecoveryAdmission(
            scope: scope, gate: .init(scope: scope, isCurrent: { true })
        )
        let binding = try XCTUnwrap(differentAdmission.bindHold(port.scope.binding.hold))
        let foreignSeal = try XCTUnwrap(differentAdmission.seal(binding: binding))
        XCTAssertNil(fixture.router.retiredProof(seal: foreignSeal), "Даже равный binding не заменяет concrete seal")
        let proof = try XCTUnwrap(fixture.router.retiredProof(seal: seal))
        XCTAssertTrue(port.detachForStorage(proof: proof))
        XCTAssertFalse(port.detachForStorage(proof: proof))
        _ = try fixture.adopt()
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 0, "Пустая очередь тоже имеет единственного владельца")
    }

    @MainActor
    func testForeignProofCannotConsumeAnotherOperationOrPoisonItsOriginalOwner() throws {
        let first = try RecoveryRetirementFixture()
        let second = try RecoveryRetirementFixture()
        XCTAssertEqual(first.router.route(type: .keyDown, event: try first.event()), .suppress)
        let proof = try first.retiredProof()
        _ = try second.retiredProof()
        XCTAssertFalse(second.operation.capturePort.detachForStorage(proof: proof))
        XCTAssertTrue(first.operation.capturePort.detachForStorage(proof: proof))
        XCTAssertFalse(first.operation.capturePort.detachForStorage(proof: proof))
        _ = try first.adopt()
        XCTAssertEqual(first.coordinator.metadata?.eventCount, 1)
        XCTAssertNil(second.coordinator.metadata)
    }

    @MainActor
    func testForeignRouterOrAttachmentCannotRetireTheOwnedQueue() throws {
        let first = try RecoveryRetirementFixture()
        let second = try RecoveryRetirementFixture()
        XCTAssertFalse(first.router.beginRetirement(second.attachment))
        XCTAssertFalse(first.operation.closeCaptureForStorage(router: second.router, attachment: first.attachment))
        XCTAssertFalse(first.operation.closeCaptureForStorage(router: first.router, attachment: second.attachment))
        XCTAssertEqual(first.router.route(type: .keyDown, event: try first.event()), .suppress)
        XCTAssertEqual(first.attachment.counters.capturedEvents, 1)
    }
}
#endif
