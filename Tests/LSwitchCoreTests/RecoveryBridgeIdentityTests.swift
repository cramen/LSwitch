#if DEBUG
import Darwin
@testable import LSwitchCore
import XCTest

final class RecoveryBridgeIdentityTests: XCTestCase {
    @MainActor
    func testDifferentSenderAndTargetUseTheProvidedSingleLedger() throws {
        let fixture = try RecoveryIsolationFixture()
        let bridge = fixture.session.bridge
        XCTAssertNotEqual(bridge.senderProcessID, bridge.processID)
        XCTAssertEqual(bridge.senderProcessID, getpid())
        XCTAssertEqual(bridge.processID, fixture.target.processID)
        XCTAssertTrue(bridge.preparePair(keyCode: 0, downFlags: 0, releaseFlags: 0))
        XCTAssertTrue(bridge.activateProtection())
        XCTAssertTrue(bridge.registerBeforePost(isDown: true))
        XCTAssertEqual(fixture.session.ledger.submissionCount, 1)
        let marker = try XCTUnwrap(bridge.marker(isDown: true))
        XCTAssertTrue(bridge.owns(senderPID: Int64(bridge.senderProcessID), marker: marker))
        XCTAssertFalse(bridge.owns(senderPID: Int64(bridge.processID), marker: marker))
        let decision = bridge.observeOwn(senderPID: Int64(bridge.senderProcessID), marker: marker,
                                         phase: .keyDown, keyCode: 0, modifierFlags: 0)
        XCTAssertTrue(decision.allowsEvent)
        bridge.recordCallbackReturn(decision, returnedNil: false)
        let snapshot = bridge.drainObservations()
        XCTAssertEqual(snapshot.ledgerSubmissionCount, fixture.session.ledger.submissionCount)
        XCTAssertEqual(snapshot.ledgerAdmittedCount, 1)
        XCTAssertTrue(fixture.session.ledger.hasUnresolvedSubmissions)
        XCTAssertFalse(snapshot.receiverCompleted)
    }

    @MainActor
    func testForeignGateOperationCannotBeBoundToAnotherLedger() throws {
        let fixture = try RecoveryIsolationFixture()
        let other = ConversionSafetyLedger(generation: 1)
        let scope = RecoveryOperationTarget(operation: other.operation, target: fixture.target)
        let gate = try XCTUnwrap(RecipientGateState(scope: scope))
        XCTAssertNil(RecoveryRecipientProbeBridge(sender: fixture.sender, target: fixture.target,
                                                 ledger: fixture.session.ledger, gate: gate,
                                                 identityCheck: { _ in true }))
        XCTAssertEqual(fixture.session.ledger.submissionCount, 0)
    }

    @MainActor
    func testFixtureMarkerAllocationDoesNotReuseNativeRegistryReservations() throws {
        let fixture = try RecoveryIsolationFixture()
        let markers = fixture.markers
        let allocated = [markers.prefixDown, markers.prefixRelease, markers.challengeDown, markers.challengeRelease]
        XCTAssertEqual(Set(allocated).count, 4)
        XCTAssertTrue(allocated.allSatisfy { $0 > 0 && $0 < (1 << 52) })
        XCTAssertTrue(fixture.session.bridge.preparePair(keyCode: 0, downFlags: 0, releaseFlags: 0))
        XCTAssertFalse(allocated.contains(try XCTUnwrap(fixture.session.bridge.marker(isDown: true))))
        XCTAssertFalse(allocated.contains(try XCTUnwrap(fixture.session.bridge.marker(isDown: false))))
    }
}
#endif
