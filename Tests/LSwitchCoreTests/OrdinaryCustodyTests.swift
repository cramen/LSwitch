#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class OrdinaryCustodyTests: XCTestCase {
    @MainActor
    func testHealthyCopiesPostInOrderOnceAndOnlyTerminalProofReleasesReservation() throws {
        let fixture = try OrdinaryCustodyFixture()
        var posted: [String] = []
        let actions = OrdinaryDispatchActions(post: { posted.append(OrdinaryCustodyFixture.text($0)) })
        let proof = try XCTUnwrap(fixture.custody.dispatch(policy: OrdinaryCustodyFixture.policy, actions: actions))
        XCTAssertEqual(posted, ["a", "b", "c"])
        XCTAssertEqual(proof.progress.attemptedPosts, 3)
        XCTAssertEqual(proof.progress.returnedPosts, 3)
        XCTAssertNil(proof.progress.failure)
        XCTAssertNil(fixture.custody.dispatch(policy: OrdinaryCustodyFixture.policy, actions: actions))
        XCTAssertTrue(fixture.recovery.coordinator.completeOrdinary(proof: proof))
        XCTAssertFalse(fixture.recovery.coordinator.completeOrdinary(proof: proof))
        XCTAssertNil(fixture.recovery.ledger.claimInput(operation: fixture.recovery.ledger.operation))
        let next = ConversionSafetyLedger(generation: 2)
        XCTAssertNotNil(fixture.recovery.coordinator.reserve(operation: next.operation,
                                                            target: proof.scope.binding.scope.target))
        XCTAssertEqual(posted.count, 3)
    }

    @MainActor
    func testEveryPostFailureRetainsFullUnmodifiedOriginalAndPossiblePostedPrefix() throws {
        for failureIndex in 0..<3 {
            let fixture = try OrdinaryCustodyFixture()
            var calls = 0
            let actions = OrdinaryDispatchActions(prepareCopy: {
                OrdinaryCustodyFixture.setText("changed", on: $0)
                return true
            }, post: { copied in
                XCTAssertEqual(OrdinaryCustodyFixture.text(copied), "changed")
                defer { calls += 1 }
                if calls == failureIndex { throw OrdinaryCustodyFixture.PostFailure.injected }
            })
            let proof = try XCTUnwrap(fixture.custody.dispatch(policy: OrdinaryCustodyFixture.policy, actions: actions))
            XCTAssertEqual(proof.progress.failure, .postFailed)
            XCTAssertEqual(proof.progress.attemptedPosts, failureIndex + 1)
            XCTAssertEqual(proof.progress.returnedPosts, failureIndex)
            XCTAssertTrue(proof.progress.possiblyAlreadyDelivered)
            XCTAssertEqual(try fixture.adopt(proof), ["a", "b", "c"])
            XCTAssertEqual(fixture.recovery.coordinator.metadata?.ordinaryDelivery, proof.progress)
            XCTAssertEqual(fixture.recovery.coordinator.metadata?.reason, .ordinaryDeliveryUnconfirmed)
            XCTAssertEqual(fixture.recovery.ledger.inputOwner, .ordinaryDelivery, "Второй claim не создаётся")
            XCTAssertNil(fixture.recovery.ledger.claimInput(operation: fixture.recovery.ledger.operation))
            XCTAssertEqual(fixture.recovery.coordinator.adoptRetainedOrdinary(proof: proof), .rejected(.noReservation))
        }
    }

    @MainActor
    func testCopyFailureAtEveryOrdinalPostsNothingAndNeverUsesOriginalAsFallback() throws {
        for failedCopy in 0..<3 {
            let fixture = try OrdinaryCustodyFixture()
            var posts = 0
            let actions = OrdinaryDispatchActions(copyAllowed: { $0 != failedCopy }, prepareCopy: {
                OrdinaryCustodyFixture.setText("changed", on: $0)
                return true
            }, post: { _ in posts += 1 })
            let proof = try XCTUnwrap(fixture.custody.dispatch(policy: OrdinaryCustodyFixture.policy, actions: actions))
            XCTAssertEqual(posts, 0, "Все копии подготавливаются до первого post")
            XCTAssertEqual(proof.progress.failure, .copyUnavailable)
            XCTAssertEqual(proof.progress.attemptedPosts, 0)
            XCTAssertFalse(proof.progress.possiblyAlreadyDelivered)
            XCTAssertEqual(try fixture.adopt(proof), ["a", "b", "c"])
        }
    }

    @MainActor
    func testCopyPreparationRefusalDoesNotModifyTheRetainedOriginal() throws {
        let fixture = try OrdinaryCustodyFixture(["kept"])
        let actions = OrdinaryDispatchActions(prepareCopy: {
            OrdinaryCustodyFixture.setText("not kept", on: $0)
            return false
        }, post: { _ in XCTFail("Нельзя отправлять original после отказа copy preparation") })
        let proof = try XCTUnwrap(fixture.custody.dispatch(policy: OrdinaryCustodyFixture.policy, actions: actions))
        XCTAssertEqual(proof.progress.failure, .copyUnavailable)
        XCTAssertEqual(try fixture.adopt(proof), ["kept"])
    }

    @MainActor
    func testEmptyQueueStillHasOneTerminalProofAndOneCompletion() throws {
        let fixture = try OrdinaryCustodyFixture([])
        let proof = try XCTUnwrap(fixture.custody.dispatch(policy: OrdinaryCustodyFixture.policy,
                                                         actions: .init(post: { _ in XCTFail("Очередь пуста") })))
        XCTAssertEqual(proof.progress.totalEvents, 0)
        XCTAssertEqual(proof.progress.attemptedPosts, 0)
        XCTAssertTrue(fixture.recovery.coordinator.completeOrdinary(proof: proof))
        XCTAssertFalse(fixture.recovery.coordinator.completeOrdinary(proof: proof))
    }
}
#endif
