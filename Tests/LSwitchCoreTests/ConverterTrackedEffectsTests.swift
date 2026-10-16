import Foundation
@testable import LSwitchCore
import XCTest

final class ConverterTrackedEffectsTests: XCTestCase {
    @MainActor
    func testPrepareRefusalRetainsBeforeTISAndPublishesNoSuccessEffects() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.configureAdapter = { $0.prepareAllowed = false }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertFalse(fixture.actions.contains("layout"))
        XCTAssertFalse(fixture.actions.contains("commit"))
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertEqual(fixture.adapters.first?.retainedClaim?.owner, .recovery)
    }

    @MainActor
    func testCommitRefusalBeforeClaimDowngradesAndRetainsWithoutReceiptCacheOrSound() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.configureAdapter = { $0.commitAllowed = false }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertEqual(fixture.ledgers.first?.decision?.input, .replayAuthorized)
        XCTAssertEqual(fixture.ledgers.first?.currentInputDisposition, .recoveryRequired)
        XCTAssertEqual(fixture.ledgers.first?.inputOwner, .recovery)
        XCTAssertEqual(fixture.adapters.first?.queued, 2)
        XCTAssertEqual(fixture.adapters.first?.retentions, 1)
        XCTAssertNil(fixture.adapters.first?.acceptedClaim)
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertTrue(fixture.converter.modeCache.isEmpty)
        XCTAssertFalse(fixture.actions.contains("sound"))
        XCTAssertFalse(fixture.actions.contains("legacyRelease"))
    }

    @MainActor
    func testViolationAfterOrdinaryClaimCannotIssueRecoveryClaimOrRetryDelivery() async throws {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.configureAdapter = { $0.failAfterClaim = true }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertTrue(try XCTUnwrap(fixture.sessions.first).ordinaryOwnershipUnconfirmed)
        XCTAssertEqual(fixture.ledgers.first?.inputOwner, .ordinaryDelivery)
        XCTAssertEqual(fixture.adapters.first?.retentions, 0)
        XCTAssertEqual(fixture.adapters.first?.delivered, 0)
        XCTAssertEqual(fixture.actions.filter { $0 == "commit" }.count, 1)
        XCTAssertNil(fixture.undoStore.pendingUndo())
        let repeated = await fixture.converter.trigger()
        XCTAssertEqual(repeated, .recoveryRequired)
        XCTAssertEqual(fixture.actions.filter { $0 == "commit" }.count, 1)
    }

    @MainActor
    func testTISFailureKeepsPartialReceiptOnlyAfterOrdinaryAcceptanceWithoutCorrectionOrSound() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility, original: "/", converted: ".")
        fixture.layoutAccepted = false
        fixture.configureAdapter = { adapter in adapter.onCommit = { XCTAssertNil(fixture.undoStore.pendingUndo()) } }
        let result = await fixture.converter.trigger(trailingText: "\u{00a0}")
        XCTAssertEqual(result, .partiallyConverted(original: "/", converted: ".", targetLayout: .russian))
        XCTAssertEqual(fixture.undoStore.pendingUndo()?.original, "/")
        XCTAssertEqual(fixture.undoStore.pendingUndo()?.trailingText, "\u{00a0}")
        XCTAssertEqual(fixture.adapters.first?.delivered, 2)
        XCTAssertTrue(fixture.adapters.first?.corrections.isEmpty == true)
        XCTAssertFalse(fixture.actions.contains("sound"))
    }

    @MainActor
    func testAlreadyTargetDoesNotSwitchOrCorrectButWaitsForDeliveryBeforeSuccess() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility, original: "руддщ", converted: "hello")
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .converted(original: "руддщ", converted: "hello"))
        XCTAssertFalse(fixture.actions.contains("layout"))
        XCTAssertTrue(fixture.adapters.first?.corrections.isEmpty == true)
        XCTAssertEqual(Array(fixture.actions.suffix(2)), ["deliver", "sound"])
    }

    @MainActor
    func testUndoUsesFreshSingleLedgerAndConsumesReceiptWithoutDuplicateConversionFeedback() async throws {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        _ = await fixture.converter.trigger()
        fixture.succeed(fixture.accessibility, original: "привет", converted: "ghbdtn")
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .undone)
        XCTAssertEqual(fixture.sessions.count, 2)
        XCTAssertFalse(fixture.ledgers[0] === fixture.ledgers[1])
        XCTAssertTrue(fixture.accessibility.requests[1].safetyLedger === fixture.ledgers[1])
        XCTAssertEqual(fixture.accessibility.requests[1].replacement, "ghbdtn")
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertEqual(fixture.actions.filter { $0 == "sound" }.count, 1)
        XCTAssertEqual(fixture.adapters.map(\.delivered), [2, 2])
    }

    @MainActor
    func testCancellationDuringEngineRetainsWithoutTISOrLegacyRelease() async {
        let fixture = TrackedConverterFixture()
        var task: Task<Converter.Outcome, Never>?
        fixture.accessibility.handler = { _ in
            task?.cancel()
            return .blocked
        }
        task = Task { await fixture.converter.trigger() }
        let result = await task?.value
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertEqual(fixture.adapters.first?.retentions, 1)
        XCTAssertFalse(fixture.actions.contains("layout"))
        XCTAssertFalse(fixture.actions.contains("legacyRelease"))
    }

    @MainActor
    func testContextChangeDuringTISPreventsClaimAndRetainsOriginalOwner() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.onSwitch = { fixture.safe = false }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertFalse(fixture.actions.contains("commit"))
        XCTAssertEqual(fixture.ledgers.first?.inputOwner, .recovery)
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertFalse(fixture.actions.contains("sound"))
    }

    @MainActor
    func testConverterRetainsPendingSessionAfterFactoryDropsItsReference() async throws {
        let fixture = TrackedConverterFixture()
        fixture.accessibility.handler = { request in
            guard let ledger = request.safetyLedger else { return .failed }
            _ = ledger.willSubmit(.text, operation: ledger.operation)
            return .failed
        }
        _ = await fixture.converter.trigger()
        weak var session = try XCTUnwrap(fixture.sessions.first)
        fixture.sessions.removeAll()
        XCTAssertNotNil(session)
        XCTAssertEqual(fixture.adapters.first?.queued, 2)
        XCTAssertTrue(fixture.converter.hasPendingRecovery)
    }

    @MainActor
    func testRefusalInsideCommitCannotGiveRecoveryClaimToOrdinaryTransport() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.configureAdapter = { adapter in
            adapter.beforeClaim = {
                guard let ledger = fixture.ledgers.first else { return XCTFail("Нужен ledger") }
                XCTAssertTrue(ledger.recordOrdinaryDeliveryRefusal(operation: ledger.operation))
            }
        }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertNil(fixture.adapters.first?.acceptedClaim)
        XCTAssertEqual(fixture.adapters.first?.delivered, 0)
        XCTAssertEqual(fixture.adapters.first?.retainedClaim?.owner, .recovery)
        XCTAssertNil(fixture.undoStore.pendingUndo())
    }

    @MainActor
    func testReportedAcceptanceWithoutClaimCannotAuthorizeAnotherTransfer() async throws {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.configureAdapter = { $0.acceptWithoutClaim = true }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertTrue(try XCTUnwrap(fixture.sessions.first).ordinaryOwnershipUnconfirmed)
        XCTAssertEqual(fixture.ledgers.first?.inputOwner, .transaction)
        XCTAssertEqual(fixture.adapters.first?.retentions, 0)
        XCTAssertNil(fixture.adapters.first?.acceptedClaim)
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertFalse(fixture.actions.contains("sound"))
    }

    @MainActor
    func testRouteCheckCannotResumeCommitAfterReentrantRetirement() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.configureAdapter = { adapter in
            adapter.onRouteCheck = {
                if fixture.actions.last == "layout" { fixture.sessions.first?.retainIfUnfinished() }
            }
        }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertEqual(fixture.adapters.first?.retentions, 1)
        XCTAssertFalse(fixture.actions.contains("commit"))
        XCTAssertEqual(fixture.ledgers.first?.inputOwner, .recovery)
        XCTAssertNil(fixture.undoStore.pendingUndo())
    }

    @MainActor
    func testContextChangeAfterAcceptedClaimCannotInventRecoveryForDeliveredQueue() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.configureAdapter = { adapter in adapter.onCommit = { fixture.safe = false } }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(fixture.ledgers.first?.inputOwner, .ordinaryDelivery)
        XCTAssertEqual(fixture.adapters.first?.delivered, 2)
        XCTAssertEqual(fixture.adapters.first?.queued, 0)
        XCTAssertEqual(fixture.adapters.first?.retentions, 0)
        XCTAssertFalse(fixture.converter.hasPendingRecovery)
        XCTAssertEqual(fixture.converter.undoContext?(), false)
        let next = await fixture.converter.trigger()
        XCTAssertEqual(next, .blockedBySafety)
        XCTAssertEqual(fixture.accessibility.requests.count, 1)
    }
}
