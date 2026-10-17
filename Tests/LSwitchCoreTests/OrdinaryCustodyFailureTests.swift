#if DEBUG
import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

final class OrdinaryCustodyFailureTests: XCTestCase {
    @MainActor
    func testRetentionBeforeDispatchCreatesOnlyAnUnpostedTerminalCapsule() throws {
        let fixture = try OrdinaryCustodyFixture()
        fixture.custody.requestRetention()
        let proof = try XCTUnwrap(fixture.custody.terminalProof)
        fixture.custody.requestRetention()
        XCTAssertTrue(fixture.custody.terminalProof === proof)
        XCTAssertNil(fixture.custody.dispatch(policy: OrdinaryCustodyFixture.policy,
                                             actions: .init(post: { _ in XCTFail("Retention запрещает dispatch") })))
        XCTAssertEqual(proof.progress.failure, .retentionRequested)
        XCTAssertEqual(proof.progress.attemptedPosts, 0)
        XCTAssertEqual(try fixture.adopt(proof), ["a", "b", "c"])
    }

    @MainActor
    func testPostReentryHasNoInternalLocksAndCannotStartAnotherDispatch() throws {
        let fixture = try OrdinaryCustodyFixture()
        let port = fixture.recovery.operation.capturePort
        let actions = OrdinaryDispatchActions(post: { _ in
            XCTAssertNil(fixture.custody.terminalProof, "In-flight post ещё не quiescent")
            XCTAssertEqual(port.close(scope: port.scope), .transferred(fixture.custody.identifier))
            fixture.custody.requestRetention()
            XCTAssertNil(fixture.custody.dispatch(policy: OrdinaryCustodyFixture.policy,
                                                 actions: .init(post: { _ in XCTFail("Reentrant post") })))
        })
        let proof = try XCTUnwrap(fixture.custody.dispatch(policy: OrdinaryCustodyFixture.policy, actions: actions))
        XCTAssertEqual(proof.progress.attemptedPosts, 1)
        XCTAssertEqual(proof.progress.returnedPosts, 1)
        XCTAssertEqual(proof.progress.failure, .retentionRequested)
        XCTAssertEqual(try fixture.adopt(proof), ["a", "b", "c"])
    }

    @MainActor
    func testDeadlineAndRouteLossStopLaterOrdinalsIncludingTheEmptyExpiredQueue() throws {
        for routeLoss in [false, true] {
            let fixture = try OrdinaryCustodyFixture()
            var clock: UInt64 = 0
            var current = true
            let policy = OrdinaryDispatchPolicy(deadline: 10, now: { clock }, canContinue: { current })
            let proof = try XCTUnwrap(fixture.custody.dispatch(policy: policy, actions: .init(post: { _ in
                if routeLoss { current = false } else { clock = 10 }
            })))
            XCTAssertEqual(proof.progress.attemptedPosts, 1)
            XCTAssertEqual(proof.progress.returnedPosts, 1)
            XCTAssertEqual(proof.progress.failure, routeLoss ? .routeUnavailable : .deadlineExceeded)
            XCTAssertEqual(try fixture.adopt(proof), ["a", "b", "c"])
        }
        let empty = try OrdinaryCustodyFixture([])
        let proof = try XCTUnwrap(empty.custody.dispatch(
            policy: .init(deadline: 0, now: { 0 }, canContinue: { true }),
            actions: .init(post: { _ in XCTFail("Expired empty queue не отправляет события") })
        ))
        XCTAssertEqual(proof.progress.failure, .deadlineExceeded)
        XCTAssertEqual(try empty.adopt(proof), [])
    }

    @MainActor
    func testRetentionInsideExternalGuardCannotBeHiddenByItsTrueReturn() throws {
        let fixture = try OrdinaryCustodyFixture()
        let policy = OrdinaryDispatchPolicy(deadline: 10, now: { 0 }, canContinue: {
            fixture.custody.requestRetention()
            return true
        })
        let proof = try XCTUnwrap(fixture.custody.dispatch(policy: policy,
                                                         actions: .init(post: { _ in XCTFail("Guard reentry") })))
        XCTAssertEqual(proof.progress.failure, .retentionRequested)
        XCTAssertEqual(proof.progress.attemptedPosts, 0)
        XCTAssertEqual(try fixture.adopt(proof), ["a", "b", "c"])
    }

    @MainActor
    func testConcurrentRetentionWaitsForInFlightPostBeforePublishingTerminalProof() throws {
        let fixture = try OrdinaryCustodyFixture()
        let custody = fixture.custody
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let policy = OrdinaryDispatchPolicy(deadline: 10, now: { 0 }, canContinue: { true })
            _ = custody.dispatch(policy: policy, actions: .init(post: { _ in
                entered.signal()
                XCTAssertEqual(proceed.wait(timeout: .now() + 3), .success)
            }))
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        defer { proceed.signal() }
        custody.requestRetention()
        XCTAssertNil(custody.terminalProof)
        proceed.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        let proof = try XCTUnwrap(custody.terminalProof)
        XCTAssertEqual(proof.progress.attemptedPosts, 1)
        XCTAssertEqual(proof.progress.returnedPosts, 1)
        XCTAssertEqual(proof.progress.failure, .retentionRequested)
        XCTAssertEqual(try fixture.adopt(proof), ["a", "b", "c"])
    }
}
#endif
