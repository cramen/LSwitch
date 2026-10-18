#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class RecoverySystemFaultDiagnosticTests: XCTestCase {
    @MainActor
    func testObservedSecureBeforeStartRefusesWithoutCaptureAndNeverClaimsProductionGuard() async throws {
        let fixture = try RecoverySystemFaultTestFixture()
        fixture.facade.observeSecureInput(enabled: true)
        fixture.facade.observeSecureInput(enabled: false)
        let started = await fixture.facade.start()
        XCTAssertFalse(started)
        XCTAssertFalse(fixture.facade.arm())
        XCTAssertEqual(fixture.driver.starts, 0)
        XCTAssertTrue(fixture.facade.report.faultLatched)
        XCTAssertFalse(fixture.facade.report.privacyGuardAccepted)
        XCTAssertFalse(fixture.facade.report.productionEnabled)
        XCTAssertFalse(fixture.facade.hasPendingInput)
        XCTAssertEqual(fixture.facade.report.session.payloadCountReads, 0)
    }

    @MainActor
    func testDisabledHeadBeforeArmCannotCreateAdmissionOrRearmOldScope() async throws {
        let fixture = try RecoverySystemFaultTestFixture()
        let started = await fixture.facade.start()
        XCTAssertTrue(started)
        let disabled = await fixture.facade.disable(.head)
        XCTAssertTrue(disabled)
        XCTAssertFalse(fixture.facade.arm())
        let repeated = await fixture.facade.disable(.tail)
        XCTAssertFalse(repeated)
        XCTAssertEqual(fixture.driver.disables, 1)
        XCTAssertFalse(fixture.facade.report.driver.headEnabled)
        XCTAssertTrue(fixture.facade.report.driver.tailEnabled)
        XCTAssertFalse(fixture.facade.hasPendingInput)
        XCTAssertEqual(fixture.facade.report.session.ledgerSubmissionCount, 0)
    }

    @MainActor
    func testSecureAfterActualMemoryCapturePreservesPrefixAndStopsLatePayloadReads() async throws {
        let fixture = try RecoverySystemFaultTestFixture()
        try await fixture.capturePrefix()
        fixture.facade.observeSecureInput(enabled: true)
        XCTAssertTrue(fixture.facade.retireForStorage())
        let first = fixture.facade.metadata?.recordIdentifier
        try fixture.latePrefix()
        XCTAssertTrue(fixture.facade.retireForStorage())
        XCTAssertEqual(fixture.facade.metadata?.recordIdentifier, first)
        XCTAssertEqual(fixture.facade.report.session.capturedEvents, 2)
        XCTAssertEqual(fixture.facade.report.session.capturedUTF16Bytes, 16)
        XCTAssertEqual(fixture.facade.report.session.payloadCountReads, 2)
        XCTAssertTrue(fixture.facade.report.session.storageOnlyAdopted)
        XCTAssertTrue(fixture.facade.report.session.inputClaimedForRecovery)
        XCTAssertEqual(try fixture.reveal(), ["kept"])
        XCTAssertFalse(fixture.facade.arm())
    }

    @MainActor
    func testHeadAndTailLossKeepOneRecoveryOwnerAndNoReadFromLateQueuedCallback() async throws {
        for endpoint: RecipientDiagnosticTap in [.head, .tail] {
            let fixture = try RecoverySystemFaultTestFixture()
            try await fixture.capturePrefix()
            let disabled = await fixture.facade.disable(endpoint)
            XCTAssertTrue(disabled)
            XCTAssertTrue(fixture.facade.retireForStorage())
            try fixture.latePrefix()
            let report = fixture.facade.report
            XCTAssertEqual(report.session.eventsRemaining, 2)
            XCTAssertEqual(report.session.payloadCountReads, 2)
            XCTAssertEqual(report.driver.loss, .tapDisabled)
            XCTAssertFalse(report.driver.permitsMutation)
            XCTAssertEqual(try fixture.reveal(), ["kept"])
            let stopped = await fixture.facade.stop()
            XCTAssertTrue(stopped)
            XCTAssertEqual(fixture.facade.report.session.eventsRemaining, 2)
        }
    }

    @MainActor
    func testForeignDriverRefusedAndEmptyInterruptedCaptureStillCreatesVisibleRecord() async throws {
        let fixture = try RecoverySystemFaultTestFixture()
        let foreign = try RecoverySystemFaultTestFixture()
        XCTAssertNil(RecoverySystemFaultDiagnostic(session: fixture.base.session, driver: foreign.driver))
        let started = await fixture.facade.start()
        XCTAssertTrue(started)
        XCTAssertTrue(fixture.facade.arm())
        fixture.facade.observeSecureInput(enabled: true)
        XCTAssertTrue(fixture.facade.retireForStorage())
        XCTAssertNotNil(fixture.facade.metadata)
        XCTAssertEqual(fixture.facade.metadata?.counts.events, 0)
        XCTAssertTrue(fixture.facade.report.session.inputClaimedForRecovery)
        XCTAssertFalse(fixture.facade.report.privacyGuardAccepted)
    }

    func testDiagnosticTimeoutPreventsLateStartAndOnlyOneReplyCanResume() async {
        let result = await withCheckedContinuation { continuation in
            let reply = RecipientDiagnosticDisableReply(continuation)
            reply.finish(false)
            XCTAssertFalse(reply.begin())
            reply.finish(true)
        }
        XCTAssertFalse(result)
        let begun = await withCheckedContinuation { continuation in
            let reply = RecipientDiagnosticDisableReply(continuation)
            XCTAssertTrue(reply.begin())
            XCTAssertFalse(reply.begin())
            reply.finish(true)
            reply.finish(false)
        }
        XCTAssertTrue(begun)
    }
}

@MainActor
private final class RecoverySystemFaultTestFixture {
    let base: RecoveryIsolationFixture
    let driver: RecoverySystemFaultTestDriver
    let facade: RecoverySystemFaultDiagnostic

    init() throws {
        base = try RecoveryIsolationFixture(clock: { 1 })
        driver = RecoverySystemFaultTestDriver(bridge: base.session.bridge)
        facade = try XCTUnwrap(RecoverySystemFaultDiagnostic(session: base.session, driver: driver))
    }

    func capturePrefix() async throws {
        let started = await facade.start()
        XCTAssertTrue(started)
        XCTAssertTrue(facade.arm())
        try latePrefix()
        XCTAssertEqual(facade.report.session.capturedEvents, 2)
    }

    func latePrefix() throws {
        for down in [true, false] {
            let event = try base.prefix(down: down)
            XCTAssertFalse(driver.state.observe(type: event.type, event: event, isHead: true))
        }
    }

    func reveal() throws -> [String] {
        let record = try XCTUnwrap(facade.metadata?.recordIdentifier)
        let projection = try XCTUnwrap(facade.actions.reveal(record))
        return projection.entries.compactMap {
            guard case .unicodeFragment(let fragment) = $0.content else { return nil }
            return fragment.text
        }
    }
}

private final class RecoverySystemFaultTestDriver: RecoverySystemFaultDriver, @unchecked Sendable {
    let bridge: RecoveryRecipientProbeBridge
    let state: RecipientTapDriverState
    @MainActor var starts = 0
    @MainActor var disables = 0

    init(bridge: RecoveryRecipientProbeBridge) {
        self.bridge = bridge
        state = RecipientTapDriverState(bridge: bridge)
    }

    var snapshot: RecipientTapDriverSnapshot { state.snapshot }
    var isProtectionAvailable: Bool { state.isProtectionAvailable }
    var permitsMutation: Bool { state.permitsMutation }
    func withProtection(_ body: () -> Void) { state.withProtection(body) }

    @MainActor func start() async -> Bool { starts += 1; state.recordInstallation(head: true, tail: true); return true }
    @MainActor func stop() async -> Bool { state.recordCleanup(); return true }
    @MainActor func refreshProtection() -> Bool { state.isProtectionAvailable }
    @MainActor func activateProtection() -> Bool {
        guard let activation = bridge.prepareActivation() else { return false }
        return state.activateProtection(activation)
    }
    @MainActor func bindFixtureCapture(router: RecoveryCaptureRouter, filter: RecoveryFixtureCaptureFilter) -> Bool {
        state.captureEndpoint.bind(router: router, filter: filter, scope: bridge.capturedScope)
    }
    @MainActor func disableOwnedTapForDiagnostics(_ tap: RecipientDiagnosticTap) async -> Bool {
        disables += 1
        state.markLost(.tapDisabled)
        state.recordHealth(head: tap != .head, tail: tap != .tail, identityMatches: true)
        return true
    }
}
#endif
