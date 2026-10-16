#if DEBUG
import Darwin
@testable import LSwitchCore
import XCTest

final class RecoveryCaptureRouterTests: XCTestCase {
    @MainActor
    func testOwnMarkersAreFilteredBeforePayloadEvenWhenTheyMatchFixturePredicate() throws {
        for useMagic in [false, true] {
            let fixture = try RecoveryOperationFixture()
            let marker = useMagic ? SyntheticEventMarker.magic : 1234
            let attachment = RecoveryCaptureAttachment(
                port: fixture.operation.capturePort,
                filter: .init(senderProcessID: getpid(), downMarker: marker, releaseMarker: 1235),
                ownMarker: { _, candidate in candidate == marker }, clock: { 1 }
            )
            let event = try RecoveryIsolationFixture.event("private fixture", marker: marker)
            XCTAssertEqual(attachment.route(type: .keyDown, event: event), .passThrough)
            XCTAssertEqual(attachment.counters.payloadCountReads, 0)
            XCTAssertEqual(attachment.counters.capturedEvents, 0)
            XCTAssertTrue(fixture.operation.capturePort.permitsMutation(for: fixture.operation.capturePort.scope))
        }
    }

    @MainActor
    func testWrongSourceMarkerOrPhasePassesWithoutReadingUnicode() throws {
        let fixture = try RecoveryOperationFixture()
        let attachment = RecoveryCaptureAttachment(
            port: fixture.operation.capturePort,
            filter: .init(senderProcessID: getpid() + 1, downMarker: 1234, releaseMarker: 1235),
            ownMarker: { _, _ in false }, clock: { 1 }
        )
        let event = try RecoveryIsolationFixture.event("private fixture", marker: 1234)
        XCTAssertEqual(attachment.route(type: .keyDown, event: event), .passThrough)
        XCTAssertEqual(attachment.route(type: .flagsChanged, event: event), .passThrough)
        XCTAssertEqual(attachment.counters.payloadCountReads, 0)
        XCTAssertEqual(attachment.counters.capturedEvents, 0)
    }

    @MainActor
    func testExpiredPortRejectsMatchingFixtureWithoutReadingItsPayload() throws {
        let fixture = try RecoveryOperationFixture()
        let port = fixture.operation.capturePort
        let attachment = RecoveryCaptureAttachment(
            port: port, filter: .init(senderProcessID: getpid(), downMarker: 1234, releaseMarker: 1235),
            ownMarker: { _, _ in false }, clock: { InputEventBuffer.maximumDuration }
        )
        let event = try RecoveryIsolationFixture.event("not retained", marker: 1234)
        XCTAssertEqual(attachment.route(type: .keyDown, event: event), .suppress)
        XCTAssertEqual(attachment.counters.payloadCountReads, 0)
        XCTAssertEqual(attachment.counters.capturedEvents, 0)
        XCTAssertEqual(attachment.counters.rejectedEvents, 1)
        XCTAssertFalse(port.permitsMutation(for: port.scope))
    }

    @MainActor
    func testForeignAttachmentCannotPublishAndForeignDetachCannotRemoveCurrentBinding() throws {
        let fixture = try RecoveryIsolationFixture()
        fixture.prepare()
        let unrelated = try RecoveryOperationFixture()
        let foreign = RecoveryCaptureAttachment(
            port: unrelated.operation.capturePort,
            filter: .init(senderProcessID: getpid(), downMarker: 1234, releaseMarker: 1235),
            ownMarker: { _, _ in false }, clock: { 1 }
        )
        XCTAssertFalse(fixture.router.attach(foreign))
        XCTAssertFalse(fixture.router.detach(foreign))
        XCTAssertEqual(fixture.router.route(type: .keyDown, event: try fixture.prefix()), .suppress)
        XCTAssertEqual(fixture.session.report.capturedEvents, 1)
        XCTAssertTrue(fixture.session.finishForRecovery())
        XCTAssertFalse(fixture.router.attach(foreign), "Старый router не rearm после передачи")
    }
}
#endif
