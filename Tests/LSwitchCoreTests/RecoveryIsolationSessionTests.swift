#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryIsolationSessionTests: XCTestCase {
    @MainActor
    func testActualCallbackCaptureUsesOneLedgerAndAdoptsWithoutPopulateOrReplay() throws {
        let fixture = try RecoveryIsolationFixture()
        fixture.prepare()
        let tap = fixture.tap()
        XCTAssertTrue(tap.handleTapEvent(type: .keyDown, event: try fixture.prefix()) == nil)
        XCTAssertTrue(tap.handleTapEvent(type: .keyUp, event: try fixture.prefix(down: false)) == nil)
        let captured = fixture.session.report
        XCTAssertEqual(captured.capturedEvents, 2)
        XCTAssertEqual(captured.capturedUTF16Bytes, 16)
        XCTAssertEqual(captured.payloadCountReads, 2)
        XCTAssertEqual(captured.ledgerSubmissionCount, 1)
        XCTAssertTrue(captured.ledgerHasUnknown)
        XCTAssertNil(fixture.session.metadata)
        XCTAssertTrue(fixture.session.finishForRecovery(on: tap))
        let completed = fixture.session.report
        XCTAssertTrue(completed.captureDetached)
        XCTAssertTrue(completed.adopted)
        XCTAssertTrue(completed.recoveryRequired)
        XCTAssertTrue(completed.inputClaimedForRecovery)
        XCTAssertFalse(completed.replayAuthorized)
        XCTAssertFalse(completed.recoveryGateAccepted)
        XCTAssertEqual(fixture.session.bridge.drainObservations().ledgerSubmissionCount, 1)
        let metadata = try XCTUnwrap(fixture.session.metadata)
        XCTAssertEqual(metadata.counts.events, 2)
        let projection = try XCTUnwrap(fixture.session.actions.reveal(metadata.recordIdentifier))
        XCTAssertEqual(projection.entries.map(\.ordinal), [0, 1])
        XCTAssertEqual(projection.entries[0].content, .unicodeFragment(.init(text: "kept")))
        XCTAssertEqual(projection.entries[1].content, .nonText(.keyRelease))
        XCTAssertTrue(fixture.session.finishForRecovery(on: tap))
        XCTAssertEqual(fixture.session.report.eventsRemaining, 2)
    }

    @MainActor
    func testUnknownEventsBypassRawProcessingBeforeDuringAndAfterAttachment() throws {
        let fixture = try RecoveryIsolationFixture()
        let unknown = try RecoveryIsolationFixture.event("must not be read", marker: fixture.markers.challengeDown)
        let tap = fixture.tap()
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: unknown), .passThrough)
        XCTAssertTrue(tap.handleTapEvent(type: .keyDown, event: unknown) != nil)
        fixture.prepare()
        XCTAssertTrue(tap.handleTapEvent(type: .keyDown, event: unknown) != nil)
        XCTAssertEqual(fixture.session.report.payloadCountReads, 0)
        XCTAssertEqual(fixture.session.report.capturedEvents, 0)
        XCTAssertTrue(fixture.session.finishForRecovery(on: tap))
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: unknown), .passThrough)
        XCTAssertTrue(tap.handleTapEvent(type: .keyDown, event: unknown) != nil)
        XCTAssertEqual(fixture.session.report.payloadCountReads, 0)
        let legacy = RecoveryCaptureRouter()
        XCTAssertEqual(legacy.route(type: .keyDown, event: unknown), .legacy)
    }

    @MainActor
    func testStopAndTapDestructionInvalidateCaptureButKeepPreviouslyAcceptedQueue() throws {
        for explicitStop in [false, true] {
            let fixture = try RecoveryIsolationFixture()
            fixture.prepare()
            var tap: EventTapCore? = fixture.tap()
            weak var released = tap
            XCTAssertTrue(tap?.handleTapEvent(type: .keyDown, event: try fixture.prefix()) == nil)
            if explicitStop { tap?.stop() }
            tap = nil
            XCTAssertNil(released)
            XCTAssertEqual(fixture.router.route(type: .keyUp, event: try fixture.prefix(down: false)), .suppress)
            XCTAssertEqual(fixture.session.report.capturedEvents, 1)
            XCTAssertEqual(fixture.session.report.payloadCountReads, 1)
            XCTAssertTrue(fixture.session.finishForRecovery())
            XCTAssertEqual(fixture.session.metadata?.counts.events, 1)
        }
    }

    @MainActor
    func testRecoveryNotificationInvalidatesWithoutRestartingOrReleasingFixtureQueue() throws {
        let fixture = try RecoveryIsolationFixture()
        fixture.prepare()
        let tap = fixture.tap()
        XCTAssertTrue(tap.handleTapEvent(type: .keyDown, event: try fixture.prefix()) == nil)
        XCTAssertTrue(tap.handleTapEvent(type: .tapDisabledByTimeout, event: try fixture.prefix()) != nil)
        XCTAssertEqual(fixture.router.route(type: .keyUp, event: try fixture.prefix(down: false)), .suppress)
        XCTAssertEqual(fixture.session.report.payloadCountReads, 1)
        XCTAssertEqual(fixture.session.report.capturedEvents, 1)
        XCTAssertTrue(fixture.session.finishForRecovery(on: tap))
    }

    @MainActor
    func testPeerLossLatchesAndNeverPromotesOldScopeAfterHealthReturns() throws {
        let fixture = try RecoveryIsolationFixture()
        fixture.prepare()
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: try fixture.prefix()), .suppress)
        fixture.session.markPeerUnavailable()
        fixture.protection.setAvailable(true)
        XCTAssertFalse(fixture.session.beginFixtureSelectionCommand())
        XCTAssertFalse(fixture.session.finishForRecovery())
        XCTAssertEqual(fixture.router.route(type: .keyUp, event: try fixture.prefix(down: false)), .suppress)
        XCTAssertEqual(fixture.session.report.capturedEvents, 1)
        XCTAssertEqual(fixture.session.report.payloadCountReads, 1)
        XCTAssertEqual(fixture.session.report.eventsRemaining, 1)
        XCTAssertTrue(fixture.session.report.retainedBeforeAdoption)
        XCTAssertTrue(fixture.session.report.preAdoptLossUnresolved)
        XCTAssertNil(fixture.session.metadata)
        XCTAssertTrue(fixture.session.bridge.snapshot.lost)
    }

    @MainActor
    func testForeignDriverOrTapCannotBindOrDetachTheCurrentOperation() throws {
        let fixture = try RecoveryIsolationFixture()
        let other = try RecoveryIsolationFixture()
        XCTAssertFalse(fixture.session.prepareCapture(router: fixture.router, protection: other.protection))
        fixture.prepare()
        XCTAssertFalse(fixture.session.prepareCapture(router: fixture.router, protection: fixture.protection))
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: try fixture.prefix()), .suppress)
        let foreignTap = other.tap()
        XCTAssertFalse(fixture.session.finishForRecovery(on: foreignTap))
        XCTAssertFalse(fixture.session.report.captureDetached)
        XCTAssertTrue(fixture.session.finishForRecovery())
        XCTAssertEqual(fixture.session.report.eventsRemaining, 1)
    }

    @MainActor
    func testLossInsidePreparationDoesNotPublishCaptureOrReadPayload() throws {
        let fixture = try RecoveryIsolationFixture()
        fixture.protection.onRefresh = { fixture.session.markPeerUnavailable() }
        XCTAssertFalse(fixture.session.prepareCapture(router: fixture.router, protection: fixture.protection))
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: try fixture.prefix()), .passThrough)
        XCTAssertEqual(fixture.session.report.capturedEvents, 0)
        XCTAssertEqual(fixture.session.report.payloadCountReads, 0)
        XCTAssertFalse(fixture.session.report.captureAttached)
    }

    @MainActor
    func testSlowExternalHealthCheckCannotExtendMutationLease() throws {
        let clock = RecoveryIsolationTestClock()
        let fixture = try RecoveryIsolationFixture(clock: { clock.read() })
        XCTAssertTrue(fixture.session.prepareCapture(router: fixture.router, protection: fixture.protection))
        fixture.protection.onRefresh = { clock.set(InputEventBuffer.maximumDuration + 1) }
        XCTAssertFalse(fixture.session.beginFixtureSelectionCommand())
        XCTAssertEqual(fixture.session.report.ledgerSubmissionCount, 0)
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: try fixture.prefix()), .suppress)
        XCTAssertEqual(fixture.session.report.payloadCountReads, 0)
        XCTAssertEqual(fixture.session.report.capturedEvents, 0)
    }
}
#endif
