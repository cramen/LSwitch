#if DEBUG
import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryStorageSessionTests: XCTestCase {
    @MainActor
    func testLossBeforeAdoptPreservesOriginalQueueForExplicitRevealWithUnavailableProtection() throws {
        let fixture = try RecoveryIsolationFixture()
        fixture.prepare()
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: try fixture.prefix()), .suppress)
        XCTAssertEqual(fixture.router.route(type: .keyUp, event: try fixture.prefix(down: false)), .suppress)
        fixture.session.markPeerUnavailable()
        XCTAssertFalse(fixture.session.finishForRecovery())
        XCTAssertTrue(fixture.session.finishForStorageRecovery())
        let result = fixture.session.report
        XCTAssertTrue(result.storageOnlyAdopted)
        XCTAssertTrue(result.ledgerHasUnknown)
        XCTAssertTrue(result.recoveryRequired)
        XCTAssertTrue(result.inputClaimedForRecovery)
        XCTAssertFalse(result.retirementPending)
        XCTAssertFalse(result.preAdoptLossUnresolved)
        XCTAssertFalse(result.replayAuthorized)
        XCTAssertEqual(result.eventsRemaining, 2)
        XCTAssertEqual(result.revealCount, 0)
        let metadata = try XCTUnwrap(fixture.session.metadata)
        XCTAssertEqual(metadata.protection, .unavailable)
        let projection = try XCTUnwrap(fixture.session.actions.reveal(metadata.recordIdentifier))
        XCTAssertEqual(projection.entries[0].content, .unicodeFragment(.init(text: "kept")))
        XCTAssertEqual(projection.entries[1].content, .nonText(.keyRelease))
        fixture.protection.setAvailable(true)
        XCTAssertFalse(fixture.session.beginFixtureSelectionCommand())
        XCTAssertTrue(fixture.session.finishForStorageRecovery())
        XCTAssertEqual(fixture.session.metadata?.recordIdentifier, metadata.recordIdentifier)
        XCTAssertEqual(fixture.session.report.eventsRemaining, 2)
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: try fixture.prefix()), .suppress)
        XCTAssertEqual(fixture.session.report.payloadCountReads, 2)
    }

    @MainActor
    func testEmptyDangerousQueueAndOutstandingKeyDebtRemainRecoveryRequired() throws {
        let fixture = try RecoveryIsolationFixture()
        XCTAssertTrue(fixture.session.prepareCapture(router: fixture.router, protection: fixture.protection))
        let ledger = fixture.session.ledger
        let down = try XCTUnwrap(ledger.willSubmit(.modifier, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: down))
        XCTAssertTrue(fixture.session.beginFixtureSelectionCommand())
        fixture.session.markFixtureSelectionUnknown(commandReturned: false)
        XCTAssertTrue(ledger.recordOutstandingKeyDebt(for: down))
        fixture.session.markPeerUnavailable()
        XCTAssertTrue(fixture.session.finishForStorageRecovery())
        XCTAssertTrue(ledger.hasOutstandingKeyDebt)
        XCTAssertTrue(ledger.hasUnknownSubmissions)
        XCTAssertEqual(ledger.decision?.input, .recoveryRequired)
        XCTAssertFalse(try XCTUnwrap(ledger.decision).permitsConfirmedResult)
        XCTAssertEqual(fixture.session.metadata?.counts.events, 0)
        XCTAssertEqual(fixture.session.metadata?.protection, .unavailable)
        XCTAssertTrue(fixture.session.report.storageOnlyAdopted)
        XCTAssertEqual(fixture.session.report.ledgerSubmissionCount, 2)
    }

    @MainActor
    func testPendingReturnsWithoutWaitingAndNextAttemptPublishesOnlyAfterOldCallbackEnds() throws {
        let barrier = RecoveryRetirementBarrier(.afterCapture)
        let fixture = try RecoveryIsolationFixture()
        XCTAssertTrue(fixture.session.prepareCapture(
            router: fixture.router, protection: fixture.protection, observePhase: { barrier.observe($0) }
        ))
        XCTAssertTrue(fixture.session.beginFixtureSelectionCommand())
        let router = fixture.router
        let event = try fixture.prefix()
        DispatchQueue.global().async {
            XCTAssertEqual(router.route(type: .keyDown, event: event), .suppress)
            barrier.finished.signal()
        }
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)
        defer { barrier.proceed.signal() }
        XCTAssertFalse(fixture.session.finishForStorageRecovery())
        XCTAssertTrue(fixture.session.report.retirementPending)
        XCTAssertFalse(fixture.session.report.storageOnlyAdopted)
        XCTAssertNil(fixture.session.metadata)
        XCTAssertNil(fixture.session.ledger.decision)
        barrier.proceed.signal()
        XCTAssertEqual(barrier.finished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(fixture.session.finishForStorageRecovery())
        XCTAssertFalse(fixture.session.report.retirementPending)
        XCTAssertTrue(fixture.session.report.selectionUnknown)
        XCTAssertEqual(fixture.session.metadata?.counts.events, 1)
        XCTAssertEqual(fixture.session.report.capturedEvents, 1)
    }

    @MainActor
    func testLossBeforeSelectionKeepsEmptyRecordWithoutInventingMutationOrCompletion() throws {
        let fixture = try RecoveryIsolationFixture()
        XCTAssertTrue(fixture.session.prepareCapture(router: fixture.router, protection: fixture.protection))
        fixture.session.markPeerUnavailable()
        XCTAssertTrue(fixture.session.finishForStorageRecovery())
        XCTAssertEqual(fixture.session.report.ledgerSubmissionCount, 0)
        XCTAssertFalse(fixture.session.report.ledgerHasUnknown)
        XCTAssertTrue(fixture.session.report.recoveryRequired)
        XCTAssertEqual(fixture.session.metadata?.counts.events, 0)
        XCTAssertEqual(fixture.session.ledger.decision?.cleanup, .noOwnedMutation)
        XCTAssertFalse(fixture.session.report.replayAuthorized)
    }

    @MainActor
    func testUnpreparedOrAlreadyProtectedTransferCannotClaimAStorageTransfer() throws {
        let fixture = try RecoveryIsolationFixture()
        XCTAssertFalse(fixture.session.finishForStorageRecovery())
        XCTAssertFalse(fixture.session.report.retirementPending)
        fixture.prepare()
        XCTAssertTrue(fixture.session.finishForRecovery())
        XCTAssertFalse(fixture.session.finishForStorageRecovery())
        XCTAssertFalse(fixture.session.report.storageOnlyAdopted)
        XCTAssertEqual(fixture.session.metadata?.counts.events, 0)
    }
}
#endif
