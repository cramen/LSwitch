#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class OrdinaryCustodyOwnershipTests: XCTestCase {
    @MainActor
    func testWrongCoordinatorCannotConsumeRetainedProofAndCorrectAdoptionStillSucceeds() throws {
        let fixture = try OrdinaryCustodyFixture()
        let foreign = try RecoveryRetirementFixture()
        fixture.custody.requestRetention()
        let proof = try XCTUnwrap(fixture.custody.terminalProof)
        XCTAssertEqual(foreign.coordinator.adoptRetainedOrdinary(proof: proof), .rejected(.wrongBinding))
        XCTAssertFalse(foreign.coordinator.completeOrdinary(proof: proof))
        XCTAssertEqual(try fixture.adopt(proof), ["a", "b", "c"])
        XCTAssertNil(foreign.coordinator.metadata)
        XCTAssertNil(fixture.recovery.ledger.claimInput(operation: fixture.recovery.ledger.operation))
    }

    @MainActor
    func testHealthyAndRetainedTerminalProofsCannotBeConsumedByTheWrongCompletionPath() throws {
        let healthy = try OrdinaryCustodyFixture(["healthy"])
        let proof = try XCTUnwrap(healthy.custody.dispatch(policy: OrdinaryCustodyFixture.policy,
                                                         actions: .init(post: { _ in })))
        XCTAssertEqual(healthy.recovery.coordinator.adoptRetainedOrdinary(proof: proof), .rejected(.wrongBinding))
        XCTAssertTrue(healthy.recovery.coordinator.completeOrdinary(proof: proof))
        let retained = try OrdinaryCustodyFixture(["retained"])
        retained.custody.requestRetention()
        let failure = try XCTUnwrap(retained.custody.terminalProof)
        XCTAssertFalse(retained.recovery.coordinator.completeOrdinary(proof: failure))
        XCTAssertEqual(try retained.adopt(failure), ["retained"])
    }

    @MainActor
    func testTerminalCapsulePreservesPayloadAfterCustodyAndPortLifetimeEnd() throws {
        var fixture: OrdinaryCustodyFixture? = try OrdinaryCustodyFixture(["survives"])
        let coordinator = try XCTUnwrap(fixture?.recovery.coordinator)
        weak var released = fixture?.custody
        fixture?.custody.requestRetention()
        let proof = try XCTUnwrap(fixture?.custody.terminalProof)
        fixture = nil
        XCTAssertNil(released, "Capsule не создаёт retain cycle с custody")
        guard case .adopted = coordinator.adoptRetainedOrdinary(proof: proof) else {
            return XCTFail("Capsule продолжает владеть оригиналом")
        }
        XCTAssertEqual(try OrdinaryCustodyFixture.reveal(coordinator), ["survives"])
        XCTAssertEqual(coordinator.metadata?.ordinaryDelivery?.attemptedPosts, 0)
    }

    @MainActor
    func testForeignQuiescenceCannotTakeQueueAndRepeatedOrdinaryTakeDoesNotExposeAnotherOwner() throws {
        let first = try RecoveryRetirementFixture()
        let second = try RecoveryRetirementFixture()
        let firstClaim = try finishOrdinary(first)
        let secondClaim = try finishOrdinary(second)
        let firstProof = try first.retiredProof()
        let secondProof = try second.retiredProof()
        XCTAssertNil(first.operation.capturePort.takeOrdinary(claim: firstClaim, quiescence: secondProof))
        XCTAssertNil(first.operation.capturePort.takeOrdinary(claim: secondClaim, quiescence: firstProof))
        let custody = try XCTUnwrap(first.operation.capturePort.takeOrdinary(claim: firstClaim, quiescence: firstProof))
        XCTAssertNil(first.operation.capturePort.takeOrdinary(claim: firstClaim, quiescence: firstProof))
        XCTAssertNotNil(second.operation.capturePort.takeOrdinary(claim: secondClaim, quiescence: secondProof))
        custody.requestRetention()
        XCTAssertNotNil(custody.terminalProof)
        XCTAssertNil(first.ledger.claimInput(operation: first.ledger.operation))
    }

    @MainActor
    func testRecoveryClaimCannotBecomeOrdinaryCustodyOrConsumeItsQuiescenceProof() throws {
        let fixture = try RecoveryRetirementFixture()
        _ = fixture.ledger.finish(operation: fixture.ledger.operation, text: .unknown,
                                   cleanup: .recoveryUnconfirmed, ordinaryRouteValid: false)
        let claim = try XCTUnwrap(fixture.ledger.claimInput(operation: fixture.ledger.operation))
        let proof = try fixture.retiredProof()
        let port = fixture.operation.capturePort
        XCTAssertNil(port.takeOrdinary(claim: claim, quiescence: proof))
        XCTAssertTrue(port.detachForStorage(proof: proof))
        guard case .adopted = port.adopt(in: fixture.coordinator, claim: claim, reason: .cleanupUnconfirmed) else {
            return XCTFail("Прежний recovery путь не ослаблен и не отравлен отказом ordinary take")
        }
        XCTAssertEqual(fixture.ledger.inputOwner, .recovery)
    }

    @MainActor
    private func finishOrdinary(_ fixture: RecoveryRetirementFixture) throws -> ConversionSafetyInputClaim {
        _ = fixture.ledger.finish(operation: fixture.ledger.operation, text: .unchangedByOperation,
                                   cleanup: .noOwnedMutation, ordinaryRouteValid: true)
        return try XCTUnwrap(fixture.ledger.claimInput(operation: fixture.ledger.operation))
    }
}
#endif
