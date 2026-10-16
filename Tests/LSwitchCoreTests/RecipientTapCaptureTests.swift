#if DEBUG
import CoreGraphics
import Darwin
import Foundation
@testable import LSwitchCore
import XCTest

final class RecipientTapCaptureTests: XCTestCase {
    @MainActor
    func testPrefixUsesCaptureAdmissionOutsideDriverLockAndNeverBecomesReceiverAdmission() throws {
        let fixture = try RecipientTapCaptureFixture()
        XCTAssertFalse(fixture.state.observe(type: .keyDown, event: try fixture.event(), isHead: true))
        XCTAssertFalse(fixture.state.observe(type: .keyUp, event: try fixture.event(down: false), isHead: true))
        XCTAssertEqual(fixture.session.report.capturedEvents, 2)
        XCTAssertEqual(fixture.session.report.payloadCountReads, 2)
        XCTAssertEqual(fixture.state.snapshot.fixtureSuppressed, 2)
        XCTAssertEqual(fixture.state.snapshot.headBlocked, 0)
        XCTAssertEqual(fixture.session.bridge.drainObservations().ledgerAdmittedCount, 0)
        XCTAssertTrue(fixture.session.finishForRecovery())
        XCTAssertEqual(fixture.session.metadata?.counts.events, 2)
    }

    @MainActor
    func testDetachedEndpointKeepsOnlyHeaderTombstoneAndSuppressesLatePrefixRelease() throws {
        let fixture = try RecipientTapCaptureFixture()
        XCTAssertFalse(fixture.state.observe(type: .keyDown, event: try fixture.event(), isHead: true))
        XCTAssertTrue(fixture.session.finishForRecovery())
        XCTAssertFalse(fixture.state.observe(type: .keyUp, event: try fixture.event(down: false), isHead: true))
        XCTAssertFalse(fixture.state.observe(type: .keyDown, event: try fixture.event(), isHead: true))
        XCTAssertEqual(fixture.session.report.capturedEvents, 1)
        XCTAssertEqual(fixture.session.report.payloadCountReads, 1)
        XCTAssertEqual(fixture.session.metadata?.counts.events, 1)
        XCTAssertEqual(fixture.state.snapshot.fixtureSuppressed, 3)
    }

    @MainActor
    func testWeakRouterDoesNotKeepSessionOrPayloadOwnerAliveButStillSuppressesHeaders() throws {
        var fixture: RecipientTapCaptureFixture? = try RecipientTapCaptureFixture()
        let state = try XCTUnwrap(fixture?.state)
        let event = try XCTUnwrap(fixture?.event(down: false))
        weak var session = fixture?.session
        weak var router = fixture?.router
        fixture = nil
        XCTAssertNil(session)
        XCTAssertNil(router)
        XCTAssertFalse(state.observe(type: .keyUp, event: event, isHead: true))
        XCTAssertEqual(state.snapshot.fixtureSuppressed, 1)
    }

    @MainActor
    func testExpiryAndLossRefuseNewPayloadReadsButKeepPrefixSuppressed() throws {
        for loseGate in [false, true] {
            let fixture = try RecipientTapCaptureFixture()
            if loseGate { fixture.state.markLost(.peerEOF) } else {
                fixture.clock.set(InputEventBuffer.maximumDuration + 1)
            }
            XCTAssertFalse(fixture.state.observe(type: .keyDown, event: try fixture.event(), isHead: true))
            XCTAssertEqual(fixture.session.report.capturedEvents, 0)
            XCTAssertEqual(fixture.session.report.payloadCountReads, 0)
            XCTAssertEqual(fixture.session.report.rejectedFixtureEvents, 1)
            XCTAssertEqual(fixture.state.snapshot.fixtureSuppressed, 1)
        }
    }

    @MainActor
    func testForeignHeadersContinueToQuarantineWithoutReadingPayload() throws {
        let foreign = try XCTUnwrap(RecoveryProcessIdentity(
            processID: getpid() + 1, birthSeconds: 1, birthMicroseconds: 0
        ))
        for wrongSource in [false, true] {
            let fixture = try RecipientTapCaptureFixture(senderOverride: wrongSource ? foreign : nil)
            let marker = wrongSource ? fixture.markers.prefixDown : fixture.markers.challengeDown
            let event = try RecoveryIsolationFixture.event("kept", marker: marker)
            XCTAssertFalse(fixture.state.observe(type: .keyDown, event: event, isHead: true))
            XCTAssertEqual(fixture.session.report.payloadCountReads, 0)
            XCTAssertEqual(fixture.state.snapshot.fixtureSuppressed, 0)
            XCTAssertEqual(fixture.state.snapshot.headBlocked, 1)
            XCTAssertTrue(fixture.session.bridge.snapshot.handoverRequested)
        }
    }

    @MainActor
    func testMalformedMatchingPrefixCannotReadPayloadOrReachTheRegistry() throws {
        let fixture = try RecipientTapCaptureFixture()
        let event = try fixture.event()
        event.type = .keyUp
        XCTAssertFalse(fixture.state.observe(type: .keyDown, event: event, isHead: true))
        XCTAssertFalse(fixture.state.observe(type: .keyUp, event: event, isHead: true))
        XCTAssertEqual(fixture.session.report.payloadCountReads, 0)
        XCTAssertEqual(fixture.state.snapshot.fixtureSuppressed, 2)
        XCTAssertEqual(fixture.state.snapshot.headBlocked, 0)
    }

    @MainActor
    func testBindingIsSingleUseAndCannotBorrowAnotherOperationOrHeaders() throws {
        let fixture = try RecipientTapCaptureFixture()
        let other = try RecipientTapCaptureFixture()
        let endpoint = RecipientTapCaptureEndpoint()
        XCTAssertFalse(endpoint.bind(router: other.router, filter: fixture.filter,
                                     scope: fixture.session.bridge.capturedScope))
        XCTAssertFalse(endpoint.bind(router: fixture.router, filter: other.filter,
                                     scope: fixture.session.bridge.capturedScope))
        XCTAssertTrue(endpoint.bind(router: fixture.router, filter: fixture.filter,
                                    scope: fixture.session.bridge.capturedScope))
        XCTAssertFalse(endpoint.bind(router: fixture.router, filter: fixture.filter,
                                     scope: fixture.session.bridge.capturedScope))
    }

    @MainActor
    func testOwnRegistryPacketSkipsCaptureAndUsesTheExistingAdmissionPath() throws {
        let fixture = try RecipientTapCaptureFixture()
        let bridge = fixture.session.bridge
        XCTAssertTrue(bridge.preparePair(keyCode: 0, downFlags: 0, releaseFlags: 0))
        XCTAssertTrue(bridge.registerBeforePost(isDown: true))
        let event = try RecoveryIsolationFixture.event("kept", marker: XCTUnwrap(bridge.marker(isDown: true)))
        XCTAssertTrue(fixture.state.observe(type: .keyDown, event: event, isHead: true))
        XCTAssertEqual(fixture.session.report.payloadCountReads, 0)
        XCTAssertEqual(fixture.state.snapshot.fixtureSuppressed, 0)
        XCTAssertEqual(bridge.drainObservations().ledgerAdmittedCount, 1)
        XCTAssertFalse(bridge.snapshot.receiverCompleted)
    }

    @MainActor
    func testCallbackAlreadyHoldingEndpointCannotCaptureOrPassThroughAfterConcurrentDetach() throws {
        let fixture = try RecipientTapCaptureFixture()
        let state = fixture.state
        let marker = fixture.markers.prefixRelease
        let clock = fixture.clock
        let finished = DispatchSemaphore(value: 0)
        clock.pauseNextRead()
        DispatchQueue.global().async {
            defer { finished.signal() }
            guard let source = CGEventSource(stateID: .privateState),
                  let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            XCTAssertFalse(state.observe(type: .keyUp, event: event, isHead: true))
        }
        XCTAssertEqual(clock.entered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(fixture.session.finishForRecovery())
        clock.proceed.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(fixture.session.report.capturedEvents, 0)
        XCTAssertEqual(fixture.session.report.payloadCountReads, 0)
        XCTAssertEqual(fixture.session.metadata?.counts.events, 0)
        XCTAssertEqual(state.snapshot.fixtureSuppressed, 1)
    }
}
#endif
