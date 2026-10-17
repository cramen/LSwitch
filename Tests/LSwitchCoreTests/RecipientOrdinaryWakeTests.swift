#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class RecipientOrdinaryWakeTests: XCTestCase {
    @MainActor
    func testRetentionCannotPublishTerminalWhileActualWakeSubmissionHasNotReturned() throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("kept")
        finishLedger(fixture)
        let entered = DispatchSemaphore(value: 0)
        let polled = DispatchSemaphore(value: 0)
        let flush = fixture.flush
        Thread {
            XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
            flush.requestRetention()
            flush.pollRetention()
            XCTAssertNil(flush.terminalProof, "Внешний postWake ещё может отправить control после снятия gate")
            polled.signal()
        }.start()
        let acceptance = flush.accept(correction: nil, claimOwnership: {
            fixture.ledger.claimInput(operation: fixture.ledger.operation)
        }, postWake: { wake in
            fixture.wake = wake
            entered.signal()
            XCTAssertEqual(polled.wait(timeout: .now() + 2), .success)
            XCTAssertNil(flush.terminalProof)
            return true
        })
        guard case .accepted = acceptance else { return XCTFail("Claim уже принят") }
        XCTAssertEqual(try fixture.retainedText(), ["kept"])
        XCTAssertEqual(flush.terminalProof?.progress.attemptedPosts, 0)
        try fixture.deliver { _ in XCTFail("Поздний control не должен повторить отправку данных") }
    }

    @MainActor
    func testSynchronousWakeCallbackFinishesNativeBatchButWaitsForWakeReturnBeforePublishing() throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("kept")
        finishLedger(fixture)
        var posts = 0
        let acceptance = fixture.flush.accept(correction: nil, claimOwnership: {
            fixture.ledger.claimInput(operation: fixture.ledger.operation)
        }, postWake: { wake in
            XCTAssertFalse(fixture.state.observe(type: .keyUp, event: wake, isHead: true,
                                                 postOrdinary: { _ in posts += 1 }))
            XCTAssertNil(fixture.flush.terminalProof)
            XCTAssertFalse(fixture.flush.transport.retentionRequested)
            return true
        })
        guard case .accepted = acceptance else { return XCTFail("Claim уже принят") }
        XCTAssertEqual(posts, 1)
        let proof = try XCTUnwrap(fixture.flush.terminalProof)
        XCTAssertNil(proof.progress.failure)
        XCTAssertTrue(fixture.coordinator.completeOrdinary(proof: proof))
    }

    @MainActor
    private func finishLedger(_ fixture: RecipientOrdinaryFixture) {
        _ = fixture.ledger.finish(operation: fixture.ledger.operation, text: .unchangedByOperation,
                                 cleanup: .noOwnedMutation, ordinaryRouteValid: true)
    }
}
#endif
