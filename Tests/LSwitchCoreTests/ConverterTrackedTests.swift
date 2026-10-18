import Foundation
@testable import LSwitchCore
import XCTest

final class ConverterTrackedTests: XCTestCase {
    @MainActor
    func testExplicitUnavailableFactoryDoesNotStartLegacyHoldEngineOrRelease() async {
        let fixture = TrackedConverterFixture()
        fixture.factoryAvailable = false
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .blockedBySafety)
        XCTAssertEqual(fixture.factoryCalls, 1)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertTrue(fixture.accessibility.requests.isEmpty)
        XCTAssertTrue(fixture.clipboard.requests.isEmpty)
        XCTAssertFalse(fixture.converter.hasPendingRecovery)
    }

    @MainActor
    func testSuccessPublishesUndoCacheAndSoundOnlyAfterSingleOrdinaryTransfer() async throws {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.configureAdapter = { adapter in
            adapter.onCommit = {
                XCTAssertNil(fixture.undoStore.pendingUndo())
                XCTAssertTrue(fixture.converter.modeCache.isEmpty)
                XCTAssertFalse(fixture.actions.contains("sound"))
            }
        }
        fixture.onSound = {
            XCTAssertEqual(fixture.adapters.first?.delivered, 2)
            XCTAssertNotNil(fixture.undoStore.pendingUndo())
        }
        let result = await fixture.converter.trigger(trailingText: "\u{00a0}")
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(fixture.actions, ["trackedHold", "drain", "mutation", "prepareDelivery", "layout",
                                        "commit", "claim", "correction", "deliver", "sound"])
        XCTAssertEqual(fixture.undoStore.pendingUndo()?.trailingText, "\u{00a0}")
        XCTAssertEqual(fixture.converter.modeCache["com.example.TextEdit"], .accessibility)
        XCTAssertEqual(fixture.ledgers.first?.inputOwner, .ordinaryDelivery)
        XCTAssertFalse(fixture.converter.hasPendingRecovery)
        XCTAssertEqual(try XCTUnwrap(fixture.adapters.first).corrections.count, 1)
    }

    @MainActor
    func testUnavailableWithoutSubmissionUsesSameLedgerForFallbackAndCommitsCacheLate() async throws {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.clipboard)
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        let first = try XCTUnwrap(fixture.accessibility.requests.first?.safetyLedger)
        XCTAssertTrue(first === fixture.clipboard.requests.first?.safetyLedger)
        XCTAssertEqual(fixture.sessions.count, 1)
        XCTAssertEqual(fixture.converter.modeCache["com.example.TextEdit"], .clipboard)
        XCTAssertEqual(fixture.actions.filter { $0 == "deliver" }.count, 1)
    }

    @MainActor
    func testUnavailableAfterSubmissionCannotFallbackAndRetainsInputWithoutFeedback() async {
        let fixture = TrackedConverterFixture()
        fixture.accessibility.handler = { request in
            guard let ledger = request.safetyLedger else { return .failed }
            _ = ledger.willSubmit(.selection, operation: ledger.operation)
            return .unavailable
        }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertTrue(fixture.clipboard.requests.isEmpty)
        XCTAssertEqual(fixture.ledgers.first?.inputOwner, .recovery)
        XCTAssertEqual(fixture.adapters.first?.queued, 2)
        XCTAssertEqual(fixture.adapters.first?.delivered, 0)
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertTrue(fixture.converter.modeCache.isEmpty)
        XCTAssertFalse(fixture.actions.contains("layout"))
        XCTAssertFalse(fixture.actions.contains("legacyRelease"))
        XCTAssertTrue(fixture.converter.hasPendingRecovery)
        let retriggered = await fixture.converter.trigger()
        XCTAssertEqual(retriggered, .recoveryRequired)
        XCTAssertEqual(fixture.factoryCalls, 1)
    }

    @MainActor
    func testProfileIsAXOnlyEvenWhenPreferencesWouldChooseClipboardOrUnicode() async throws {
        let fixture = TrackedConverterFixture()
        fixture.profile = try ConversionSafetyProfileFixture().binding
        fixture.boundAXEngine = fixture.accessibility
        fixture.mechanisms = [.accessibility]
        fixture.clipboardPreferred = true
        fixture.unicodePreferred = true
        fixture.succeed(fixture.accessibility)
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(fixture.accessibility.requests.count, 1)
        XCTAssertTrue(fixture.clipboard.requests.isEmpty)
        XCTAssertTrue(fixture.unicode.requests.isEmpty)
        XCTAssertEqual(fixture.ledgers.first?.decision?.verificationBasis, .observedUnderProfile)
        XCTAssertTrue(try XCTUnwrap(fixture.ledgers.first).hasUnresolvedSubmissions)
    }

    @MainActor
    func testClaimedSuccessWithoutLedgerEvidenceNeverChangesLayoutOrPublishesReceipt() async {
        let fixture = TrackedConverterFixture()
        fixture.accessibility.result = .success(.init(original: "ghbdtn", converted: "привет"))
        let retriggered = await fixture.converter.trigger()
        XCTAssertEqual(retriggered, .recoveryRequired)
        XCTAssertFalse(fixture.actions.contains("layout"))
        XCTAssertFalse(fixture.actions.contains("sound"))
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertEqual(fixture.ledgers.first?.currentInputDisposition, .recoveryRequired)
        XCTAssertEqual(fixture.adapters.first?.delivered, 0)
    }

    @MainActor
    func testContextLossWhileDrainingRetainsWithoutRunningAnyEngine() async {
        let fixture = TrackedConverterFixture()
        fixture.configureAdapter = { adapter in adapter.drain = { fixture.safe = false } }
        let retriggered = await fixture.converter.trigger()
        XCTAssertEqual(retriggered, .recoveryRequired)
        XCTAssertTrue(fixture.accessibility.requests.isEmpty)
        XCTAssertEqual(fixture.adapters.first?.retentions, 1)
        XCTAssertFalse(fixture.actions.contains("legacyRelease"))
    }

    @MainActor
    func testSafeNoMutationFailureForwardsOnceWithoutLayoutCorrectionReceiptOrSound() async {
        let fixture = TrackedConverterFixture()
        fixture.mechanisms = [.accessibility]
        fixture.accessibility.result = .blocked
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .blockedBySafety)
        XCTAssertEqual(fixture.adapters.first?.delivered, 2)
        XCTAssertTrue(fixture.adapters.first?.corrections.isEmpty == true)
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertFalse(fixture.actions.contains("layout"))
        XCTAssertFalse(fixture.actions.contains("sound"))
    }
}
