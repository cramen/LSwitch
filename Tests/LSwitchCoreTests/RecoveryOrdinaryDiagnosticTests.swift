#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryOrdinaryDiagnosticTests: XCTestCase {
    @MainActor
    func testRetainBetweenOrdinaryClaimAndCompletionTaskDoesNotStealQuiescenceProof() async throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("kept")
        let diagnostic = try diagnostic(fixture)
        diagnostic.ordinaryAcceptanceStarted = true
        try fixture.accept()
        XCTAssertEqual(fixture.ledger.inputOwner, .ordinaryDelivery)
        XCTAssertNil(diagnostic.completionTask)
        let retained = await diagnostic.retainForRecovery()
        XCTAssertFalse(retained, "До completion publication это pending, не storage fallback")
        XCTAssertTrue(fixture.flush.transport.retentionRequested)
        XCTAssertNil(fixture.flush.terminalProof)
        fixture.flush.pollRetention()
        XCTAssertEqual(try fixture.retainedText(), ["kept"], "Flush по-прежнему владеет единственным proof")
        XCTAssertEqual(fixture.flush.terminalProof?.progress.attemptedPosts, 0)
        XCTAssertEqual(fixture.ledger.inputOwner, .ordinaryDelivery)
        XCTAssertNil(fixture.ledger.claimInput(operation: fixture.ledger.operation))
    }

    @MainActor
    func testAcceptedPhaseBeforeClaimRetainsThroughTheSameFlushWithoutStorageFallback() async throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("kept")
        let diagnostic = try diagnostic(fixture)
        diagnostic.ordinaryAcceptanceStarted = true
        let retained = await diagnostic.retainForRecovery()
        XCTAssertFalse(retained)
        XCTAssertEqual(fixture.ledger.inputOwner, .transaction)
        XCTAssertTrue(fixture.flush.transport.retentionRequested)
        try fixture.accept()
        fixture.flush.pollRetention()
        XCTAssertEqual(try fixture.retainedText(), ["kept"])
        XCTAssertEqual(fixture.flush.terminalProof?.progress.attemptedPosts, 0)
        XCTAssertEqual(fixture.claims, 1)
    }

    @MainActor
    private func diagnostic(_ fixture: RecipientOrdinaryFixture) throws -> RecoveryOrdinaryDiagnostic {
        let driver = try XCTUnwrap(RecipientTapDriver(bridge: fixture.bridge))
        let value = RecoveryOrdinaryDiagnostic(resources: .init(
            ledger: fixture.ledger, coordinator: fixture.coordinator, driver: driver,
            sender: fixture.bridge.capturedSenderIdentity, target: fixture.bridge.capturedTargetIdentity,
            router: fixture.router
        ), wakeMarker: fixture.flush.marker.value)
        value.operation = fixture.operation
        value.attachment = fixture.attachment
        value.capture = fixture.capture
        value.flush = fixture.flush
        // Driver не запускается; recipient fixture заменяет системный callback чистым state.
        return value
    }
}
#endif
