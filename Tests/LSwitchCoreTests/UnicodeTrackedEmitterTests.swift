import CoreGraphics
@testable import LSwitchCore
import XCTest

final class UnicodeTrackedEmitterTests: XCTestCase {
    @MainActor
    func testActualDownAndUpAreJournaledBeforeEachPostAndRemainPendingWithoutReceiverProof() throws {
        let ledger = ConversionSafetyLedger(generation: 1)
        var posted: [CGEventType] = []
        var replies: [ConversionDispatchReply] = []
        let packet = try XCTUnwrap(UnicodeEventEmitter.prepare("привет", targetPID: 123) { event, target in
            XCTAssertEqual(target, 123)
            posted.append(event.type)
            XCTAssertEqual(ledger.submissionCount, posted.count)
            XCTAssertEqual(replies.count, posted.count - 1)
        })
        let hooks = ConversionDispatchHooks(beforeSend: { kind in
            kind.isCleanup ? ledger.willSubmitCleanup(kind, operation: ledger.operation)
                : ledger.willSubmit(kind, operation: ledger.operation)
        }, didReturn: { reply in
            replies.append(reply)
            ledger.observe(.adapterReturned(reply.returnedSuccessfully), for: reply.submission)
        })
        XCTAssertEqual(packet.postTracked?({ true }, hooks), true)
        XCTAssertEqual(posted, [.keyDown, .keyUp])
        XCTAssertTrue(ledger.hasUnresolvedSubmissions)
        XCTAssertFalse(packet.post { true }, "Один consumed state защищает оба API")
        XCTAssertEqual(packet.postTracked?({ true }, hooks), false)
    }

    @MainActor
    func testDeniedDownTokenCannotFallThroughToUntrackedPacket() throws {
        var count = 0
        let packet = try XCTUnwrap(UnicodeEventEmitter.prepare("привет", targetPID: 124) { _, _ in count += 1 })
        let hooks = ConversionDispatchHooks(beforeSend: { _ in nil }, didReturn: { _ in XCTFail("Нет post") })
        XCTAssertEqual(packet.postTracked?({ true }, hooks), false)
        XCTAssertFalse(packet.post { true })
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testCompletedDownWithDeniedUpRecordsIndependentDebtAndCannotAuthorizeReplay() throws {
        let ledger = ConversionSafetyLedger(generation: 3)
        var posted: [CGEventType] = []
        let packet = try XCTUnwrap(UnicodeEventEmitter.prepare("привет", targetPID: 125) { event, target in
            XCTAssertEqual(target, 125)
            posted.append(event.type)
        })
        let hooks = ConversionDispatchHooks(beforeSend: { kind in
            kind == .text ? ledger.willSubmit(kind, operation: ledger.operation) : nil
        }, didReturn: { ledger.observe(.receiverCompleted, for: $0.submission) }, didLeaveDebt: {
            XCTAssertTrue(ledger.recordOutstandingKeyDebt(for: $0))
        })
        XCTAssertEqual(packet.postTracked?({ true }, hooks), true, "Down действительно отправлен")
        XCTAssertEqual(posted, [.keyDown])
        XCTAssertEqual(ledger.submissionCount, 1)
        XCTAssertFalse(ledger.hasUnresolvedSubmissions)
        XCTAssertTrue(ledger.hasOutstandingKeyDebt)
        let final = try XCTUnwrap(ledger.finish(
            operation: ledger.operation, text: .confirmed, cleanup: .recoveredObserved, ordinaryRouteValid: true
        ))
        XCTAssertEqual(final.input, .recoveryRequired)
        XCTAssertFalse(final.permitsConfirmedResult)
    }

    @MainActor
    func testFocusLossAfterTrackedDownAllowsOnlyBalancingUpToCapturedPID() throws {
        let ledger = ConversionSafetyLedger(generation: 4)
        var valid = true
        var posted: [CGEventType] = []
        let packet = try XCTUnwrap(UnicodeEventEmitter.prepare("привет", targetPID: 126) { event, target in
            XCTAssertEqual(target, 126)
            posted.append(event.type)
            if event.type == .keyDown { valid = false }
        })
        let hooks = ConversionDispatchHooks(beforeSend: { kind in
            if kind == .balancingRelease { return ledger.willSubmitCleanup(kind, operation: ledger.operation) }
            return valid ? ledger.willSubmit(kind, operation: ledger.operation) : nil
        }, didReturn: { ledger.observe(.adapterReturned(true), for: $0.submission) })
        XCTAssertEqual(packet.postTracked?({ valid }, hooks), true)
        XCTAssertEqual(posted, [.keyDown, .keyUp])
    }
}
