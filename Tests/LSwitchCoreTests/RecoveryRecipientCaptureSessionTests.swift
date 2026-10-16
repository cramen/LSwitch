#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryRecipientCaptureSessionTests: XCTestCase {
    @MainActor
    func testRecipientBindingPrecedesSelectionAndExcludesTheSessionTapRoute() throws {
        let fixture = try RecoveryIsolationFixture()
        var endpoint: RecoveryCaptureRouter?
        var acceptedFilter: RecoveryFixtureCaptureFilter?
        XCTAssertTrue(fixture.session.prepareRecipientCapture(protection: fixture.protection, bind: { router, filter in
            XCTAssertEqual(fixture.session.ledger.submissionCount, 0)
            XCTAssertTrue(router.matchesCapture(scope: fixture.session.bridge.capturedScope, filter: filter))
            endpoint = router
            acceptedFilter = filter
            return true
        }))
        XCTAssertFalse(fixture.session.prepareCapture(router: fixture.router, protection: fixture.protection))
        XCTAssertTrue(fixture.session.beginFixtureSelectionCommand())
        fixture.session.markFixtureSelectionUnknown(commandReturned: true)
        let router = try XCTUnwrap(endpoint)
        let filter = try XCTUnwrap(acceptedFilter)
        XCTAssertEqual(router.route(type: .keyDown, event: try fixture.prefix()), .suppress)
        XCTAssertEqual(router.route(type: .keyUp, event: try fixture.prefix(down: false)), .suppress)
        XCTAssertEqual(fixture.session.report.capturedEvents, 2)
        XCTAssertTrue(fixture.session.finishForRecovery())
        XCTAssertFalse(router.matchesCapture(scope: fixture.session.bridge.capturedScope, filter: filter))
        let before = fixture.session.report
        XCTAssertEqual(router.route(type: .keyDown, event: try fixture.prefix()), .suppress)
        XCTAssertEqual(router.route(type: .keyUp, event: try fixture.prefix(down: false)), .suppress)
        XCTAssertEqual(fixture.session.report.payloadCountReads, before.payloadCountReads)
        XCTAssertEqual(fixture.session.report.eventsRemaining, 2)
    }

    @MainActor
    func testBinderRefusalClosesOldScopeBeforeAnySelectionOrPayloadRead() throws {
        let fixture = try RecoveryIsolationFixture()
        var retainedRouter: RecoveryCaptureRouter?
        XCTAssertFalse(fixture.session.prepareRecipientCapture(protection: fixture.protection, bind: { router, _ in
            retainedRouter = router
            return false
        }))
        XCTAssertFalse(fixture.session.beginFixtureSelectionCommand())
        XCTAssertEqual(fixture.session.ledger.submissionCount, 0)
        XCTAssertEqual(try XCTUnwrap(retainedRouter).route(type: .keyDown, event: try fixture.prefix()), .suppress)
        XCTAssertEqual(fixture.session.report.payloadCountReads, 0)
        XCTAssertEqual(fixture.session.report.capturedEvents, 0)
        XCTAssertTrue(fixture.session.bridge.snapshot.lost)
    }

    @MainActor
    func testExpiryInsideBinderCannotPublishPermissionForASelection() throws {
        let clock = RecoveryIsolationTestClock()
        let fixture = try RecoveryIsolationFixture(clock: { clock.read() })
        XCTAssertFalse(fixture.session.prepareRecipientCapture(protection: fixture.protection, bind: { _, _ in
            clock.set(InputEventBuffer.maximumDuration + 1)
            return true
        }))
        XCTAssertFalse(fixture.session.beginFixtureSelectionCommand())
        XCTAssertEqual(fixture.session.report.ledgerSubmissionCount, 0)
        XCTAssertEqual(fixture.session.report.payloadCountReads, 0)
        XCTAssertTrue(fixture.session.report.preAdoptLossUnresolved)
    }

    @MainActor
    func testCaptureMetadataBindingRejectsForeignOperationAndHeaders() throws {
        let fixture = try RecoveryIsolationFixture()
        let other = try RecoveryIsolationFixture()
        XCTAssertTrue(fixture.session.prepareRecipientCapture(protection: fixture.protection, bind: { router, filter in
            XCTAssertFalse(router.matchesCapture(scope: other.session.bridge.capturedScope, filter: filter))
            let wrong = RecoveryFixtureCaptureFilter(senderProcessID: filter.senderProcessID,
                                                     downMarker: filter.releaseMarker, releaseMarker: filter.downMarker)
            XCTAssertFalse(router.matchesCapture(scope: fixture.session.bridge.capturedScope, filter: wrong))
            return true
        }))
    }

    @MainActor
    func testDetachedTombstoneIsMetadataOnlyAndCannotAdmitUnknownHeaders() throws {
        let fixture = try RecoveryIsolationFixture()
        fixture.prepare()
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: try fixture.prefix()), .suppress)
        XCTAssertTrue(fixture.session.finishForRecovery())
        let before = fixture.session.report
        // Даже неверная phase с прежним source+marker не должна пройти после detach.
        XCTAssertEqual(fixture.router.route(type: .keyUp, event: try fixture.prefix()), .suppress)
        let unknown = try RecoveryIsolationFixture.event("not read", marker: fixture.markers.challengeDown)
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: unknown), .passThrough)
        XCTAssertEqual(fixture.session.report.payloadCountReads, before.payloadCountReads)
        XCTAssertEqual(fixture.session.report.capturedEvents, before.capturedEvents)
    }

    @MainActor
    func testSessionOwnsRouterWithoutDriverOrExpiryRetainingTheSession() throws {
        weak var session: RecoveryIsolationSession?
        weak var router: RecoveryCaptureRouter?
        do {
            let fixture = try RecoveryIsolationFixture()
            session = fixture.session
            XCTAssertTrue(fixture.session.prepareRecipientCapture(protection: fixture.protection, bind: { endpoint, _ in
                router = endpoint
                return true
            }))
            XCTAssertNotNil(router, "Session удерживает router после возврата binder")
        }
        XCTAssertNil(session)
        XCTAssertNil(router, "Weak expiry не должен удерживать endpoint после завершения владельца")
    }
}
#endif
