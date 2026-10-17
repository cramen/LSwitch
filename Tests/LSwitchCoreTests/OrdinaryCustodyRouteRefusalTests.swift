#if DEBUG
import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

final class OrdinaryCustodyRouteRefusalTests: XCTestCase {
    @MainActor
    func testFinalRouteRefusalPreservesOriginalsAndTheSameClaimAfterEveryPostReturned() throws {
        let fixture = try OrdinaryCustodyFixture()
        var posted: [String] = []
        let proof = try XCTUnwrap(fixture.custody.dispatch(policy: OrdinaryCustodyFixture.policy, actions: .init(
            prepareCopy: { OrdinaryCustodyFixture.setText("changed", on: $0); return true },
            post: { posted.append(OrdinaryCustodyFixture.text($0)) }
        )))
        let retained = try XCTUnwrap(proof.retainingAfterRouteRefusal())
        XCTAssertEqual(posted, ["changed", "changed", "changed"])
        XCTAssertEqual(retained.scope, proof.scope)
        XCTAssertTrue(retained.seal === proof.seal)
        XCTAssertEqual(retained.claim, fixture.claim)
        XCTAssertEqual(retained.transportIdentifier, proof.transportIdentifier)
        XCTAssertEqual(retained.progress, .init(totalEvents: 3, attemptedPosts: 3, returnedPosts: 3,
                                               failure: .routeUnavailable))
        XCTAssertTrue(retained.progress.possiblyAlreadyDelivered)
        XCTAssertNil(proof.retainingAfterRouteRefusal())
        XCTAssertFalse(fixture.recovery.coordinator.completeOrdinary(proof: proof))
        XCTAssertNil(proof.takeRetained(seal: proof.seal))
        XCTAssertEqual(try fixture.adopt(retained), ["a", "b", "c"])
        XCTAssertEqual(fixture.recovery.coordinator.metadata?.ordinaryDelivery, retained.progress)
        XCTAssertNil(fixture.recovery.ledger.claimInput(operation: fixture.claim.operation))
        XCTAssertNil(retained.takeRetained(seal: retained.seal))
    }

    @MainActor
    func testEmptySuccessfulQueueStillRetainsAnExplicitRouteFailureRecord() throws {
        let fixture = try OrdinaryCustodyFixture([])
        let proof = try successfulProof(fixture)
        let retained = try XCTUnwrap(proof.retainingAfterRouteRefusal())
        XCTAssertEqual(retained.progress.failure, .routeUnavailable)
        XCTAssertFalse(retained.progress.possiblyAlreadyDelivered)
        XCTAssertEqual(try fixture.adopt(retained), [])
        XCTAssertEqual(fixture.recovery.coordinator.metadata?.eventCount, 0)
    }

    @MainActor
    func testCompletedAndAlreadyRetainedProofsCannotProduceAnotherCapsule() throws {
        let completed = try OrdinaryCustodyFixture(["completed"])
        let success = try successfulProof(completed)
        XCTAssertTrue(completed.recovery.coordinator.completeOrdinary(proof: success))
        XCTAssertNil(success.retainingAfterRouteRefusal())
        XCTAssertFalse(completed.recovery.coordinator.completeOrdinary(proof: success))
        let fixture = try OrdinaryCustodyFixture(["retained"])
        fixture.custody.requestRetention()
        let failure = try XCTUnwrap(fixture.custody.terminalProof)
        XCTAssertNil(failure.retainingAfterRouteRefusal())
        XCTAssertEqual(failure.progress.failure, .retentionRequested)
        XCTAssertEqual(try fixture.adopt(failure), ["retained"])
    }

    @MainActor
    func testForeignConsumerCannotPoisonTransferredProofOrConsumeItsOriginals() throws {
        let fixture = try OrdinaryCustodyFixture(["owned"])
        let foreign = try OrdinaryCustodyFixture(["foreign"])
        let proof = try successfulProof(fixture)
        let foreignProof = try successfulProof(foreign)
        let retained = try XCTUnwrap(proof.retainingAfterRouteRefusal())
        XCTAssertNil(retained.takeRetained(seal: foreignProof.seal))
        XCTAssertFalse(foreign.recovery.coordinator.completeOrdinary(proof: retained))
        XCTAssertEqual(foreign.recovery.coordinator.adoptRetainedOrdinary(proof: retained), .rejected(.wrongBinding))
        XCTAssertEqual(try fixture.adopt(retained), ["owned"])
        XCTAssertTrue(foreign.recovery.coordinator.completeOrdinary(proof: foreignProof))
    }

    @MainActor
    func testConcurrentRouteRefusalsTransferExactlyOneCapsule() throws {
        let fixture = try OrdinaryCustodyFixture()
        let proof = try successfulProof(fixture)
        let results = OrdinaryRouteRaceResults()
        let group = DispatchGroup()
        for _ in 0..<2 {
            DispatchQueue.global().async(group: group) { results.record(proof.retainingAfterRouteRefusal()) }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(results.proofs.count, 1)
        XCTAssertFalse(proof.consumeCompletion(seal: proof.seal))
        let retained = try XCTUnwrap(results.proofs.first)
        XCTAssertEqual(try fixture.adopt(retained), ["a", "b", "c"])
    }

    @MainActor
    func testCompletionAndRouteRefusalCannotBothConsumeTheSameSuccessfulCapsule() throws {
        let fixture = try OrdinaryCustodyFixture()
        let proof = try successfulProof(fixture)
        let results = OrdinaryRouteRaceResults()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { results.record(proof.retainingAfterRouteRefusal()) }
        DispatchQueue.global().async(group: group) {
            results.recordCompletion(proof.consumeCompletion(seal: proof.seal))
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(results.proofs.count + (results.completed ? 1 : 0), 1)
        XCTAssertNil(proof.retainingAfterRouteRefusal())
        XCTAssertFalse(proof.consumeCompletion(seal: proof.seal))
        if let retained = results.proofs.first {
            XCTAssertEqual(try fixture.adopt(retained), ["a", "b", "c"])
        }
    }

    @MainActor
    private func successfulProof(_ fixture: OrdinaryCustodyFixture) throws -> OrdinaryTerminalProof {
        try XCTUnwrap(fixture.custody.dispatch(policy: OrdinaryCustodyFixture.policy, actions: .init(post: { _ in })))
    }
}

private final class OrdinaryRouteRaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedProofs: [OrdinaryTerminalProof] = []
    private var didComplete = false

    var proofs: [OrdinaryTerminalProof] { lock.lock(); defer { lock.unlock() }; return storedProofs }
    var completed: Bool { lock.lock(); defer { lock.unlock() }; return didComplete }

    func record(_ proof: OrdinaryTerminalProof?) {
        lock.lock()
        defer { lock.unlock() }
        if let proof { storedProofs.append(proof) }
    }

    func recordCompletion(_ completed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        didComplete = completed
    }
}
#endif
