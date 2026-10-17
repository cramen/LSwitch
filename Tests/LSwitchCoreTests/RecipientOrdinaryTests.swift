#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class RecipientOrdinaryTests: XCTestCase {
    @MainActor
    func testWakeSealsLatestCapturedTailAndDispatchesOneOrderedCopyBatchBeforeNormalRoute() throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("first")
        try fixture.accept()
        try fixture.enqueue("tail")
        var posted: [String] = []
        try fixture.deliver { event in
            posted.append(OrdinaryCustodyFixture.text(event))
            XCTAssertNotNil(fixture.state.snapshot)
        }
        XCTAssertEqual(posted, ["first", "tail"])
        XCTAssertEqual(fixture.claims, 1)
        let proof = try XCTUnwrap(fixture.flush.terminalProof)
        XCTAssertNil(proof.progress.failure)
        XCTAssertEqual(proof.progress.returnedPosts, 2)
        XCTAssertTrue(fixture.coordinator.completeOrdinary(proof: proof))
        let next = try RecoveryOperationFixture.event("next")
        XCTAssertTrue(fixture.state.observe(type: .keyDown, event: next, isHead: true))
        try fixture.deliver { _ in XCTFail("Поздний marker не повторяет batch") }
        XCTAssertEqual(fixture.attachment.counters.capturedEvents, 2)
    }

    @MainActor
    func testCorrectionOnlyChangesCopiedEventsAndRetainedOriginalKeepsUserData() throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("цщкдв")
        try fixture.enqueue("next")
        try fixture.accept(correction: .init(source: .russian, target: .english, startedAt: 5, completedAt: 15))
        var posted = 0
        try fixture.deliver { event in
            posted += 1
            XCTAssertEqual(OrdinaryCustodyFixture.text(event), "world")
            XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), 7711)
            fixture.flush.transport.requestRetention()
        }
        XCTAssertEqual(posted, 1)
        XCTAssertEqual(try fixture.retainedText(), ["цщкдв", "next"])
        XCTAssertEqual(fixture.claims, 1)
        XCTAssertFalse(fixture.state.observe(type: .keyDown, event: try RecoveryOperationFixture.event("later"),
                                              isHead: true))
    }

    @MainActor
    func testDeadlineBeforeWakeKeepsOriginalAndSuppressesLateMarkerWithoutPosting() throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("kept")
        try fixture.accept()
        fixture.clock.set(100)
        fixture.flush.pollRetention()
        try fixture.deliver { _ in XCTFail("Marker после deadline не отправляет данные") }
        XCTAssertEqual(try fixture.retainedText(), ["kept"])
        XCTAssertEqual(fixture.flush.terminalProof?.progress.attemptedPosts, 0)
    }

    @MainActor
    func testFailedWakePostIsAcceptedOnceThenRetainedWithNoRetry() throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("kept")
        try fixture.accept(postsWake: false)
        fixture.flush.pollRetention()
        let again = fixture.flush.accept(correction: nil, claimOwnership: {
            XCTFail("Повторный claim запрещён")
            return nil
        }, postWake: { _ in XCTFail("Повторный marker запрещён"); return true })
        guard case .refused = again else { return XCTFail("Повторный accept должен быть отказом") }
        XCTAssertEqual(try fixture.retainedText(), ["kept"])
    }

    @MainActor
    func testLostDriverAfterClaimUsesStorageQuiescenceWithoutProxy() throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("kept")
        try fixture.accept()
        fixture.state.markLost(.tapDisabled)
        fixture.flush.pollRetention()
        XCTAssertEqual(try fixture.retainedText(), ["kept"])
        XCTAssertEqual(fixture.flush.terminalProof?.progress.attemptedPosts, 0)
        XCTAssertEqual(fixture.ledger.inputOwner, .ordinaryDelivery)
    }

    @MainActor
    func testMalformedWakeSuppressesWithoutPayloadCopyOrNativeDispatch() throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("kept")
        try fixture.accept()
        let wake = try XCTUnwrap(fixture.wake)
        wake.type = .keyDown
        XCTAssertFalse(fixture.state.observe(type: .keyDown, event: wake, isHead: true, postOrdinary: { _ in
            XCTFail("Неправильный shape не выдаёт proxy для отправки")
        }))
        XCTAssertEqual(try fixture.retainedText(), ["kept"])
        XCTAssertEqual(fixture.attachment.counters.payloadCountReads, 1)
    }

    @MainActor
    func testPostFailureRetainsFullOriginalAndNeverRetriesAttemptedPrefix() throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("first")
        try fixture.enqueue("second")
        try fixture.accept()
        try fixture.deliver { _ in throw OrdinaryCustodyFixture.PostFailure.injected }
        XCTAssertEqual(fixture.flush.terminalProof?.progress.attemptedPosts, 1)
        XCTAssertEqual(fixture.flush.terminalProof?.progress.returnedPosts, 0)
        XCTAssertEqual(try fixture.retainedText(), ["first", "second"])
        try fixture.deliver { _ in XCTFail("Уже попытанный префикс не повторяется") }
    }

    @MainActor
    func testPhysicalMouseDownDoesNotCancelAnAlreadyActiveRecipientGesture() throws {
        let fixture = try RecipientOrdinaryFixture()
        fixture.state.recordPhysicalButtons(released: false)
        try fixture.enqueue("", type: .leftMouseDown)
        try fixture.enqueue("", type: .leftMouseDragged)
        try fixture.enqueue("", type: .leftMouseUp)
        XCTAssertTrue(fixture.state.permitsMutation)
        try fixture.accept()
        var types: [CGEventType] = []
        try fixture.deliver { types.append($0.type) }
        XCTAssertEqual(types, [.leftMouseDown, .leftMouseDragged, .leftMouseUp])
        XCTAssertEqual(fixture.attachment.counters.payloadCountReads, 0)
    }
}
#endif
