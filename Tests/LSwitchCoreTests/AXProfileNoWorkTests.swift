import Foundation
@testable import LSwitchCore
import XCTest

final class AXProfileNoWorkTests: XCTestCase {
    @MainActor
    func testManualEmptyWhitespaceAndStartCaretObserveNoWorkWithoutMutationOrReceipt() async throws {
        let cases: [(String, Int)] = [("", 0), (" \t\n", 3), ("123 !?", 6), ("ghbdtn", 0)]
        for (text, caret) in cases {
            let fixture = try AXProfileFixture(text)
            fixture.access.model.currentSelection = NSRange(location: caret, length: 0)
            let operation = try fixture.prepare()
            let result = await operation.converter.performWithEvidence(ConversionRequest(
                safetyLedger: operation.ledger, beginMutation: { XCTFail("No-work не начинает mutation"); return false }
            ))
            XCTAssertEqual(result.result, .unavailable)
            XCTAssertEqual(result.cleanup, .noOwnedMutation)
            XCTAssertEqual(fixture.snapshotReads, 2, "Обязателен fresh exact repeat")
            XCTAssertTrue(fixture.access.model.selectionWrites.isEmpty)
            XCTAssertEqual(fixture.access.model.textWrites, 0)
            XCTAssertEqual(operation.ledger.submissionCount, 0)
            XCTAssertFalse(operation.ledger.hasProfileFault)
            let decision = try XCTUnwrap(operation.ledger.finishUsingRecordedCleanup(
                operation: operation.ledger.operation, text: .unchangedByOperation, ordinaryRouteValid: true
            ))
            XCTAssertEqual(decision.input, .replayAuthorized)
            XCTAssertFalse(decision.permitsConfirmedResult)
        }
    }

    @MainActor
    func testMissingOrMalformedInitialSnapshotIsStillFaultWithoutASetter() async throws {
        for missing in [false, true] {
            let fixture = try AXProfileFixture("")
            let operation = try fixture.prepare()
            if missing { fixture.missingSnapshot = true } else { fixture.countOverride = 1 }
            let result = await operation.converter.performWithEvidence(
                ConversionRequest(safetyLedger: operation.ledger)
            )
            XCTAssertEqual(result.result, .unavailable)
            XCTAssertTrue(operation.ledger.hasProfileFault)
            XCTAssertEqual(fixture.snapshotReads, 1)
            XCTAssertEqual(operation.ledger.submissionCount, 0)
            XCTAssertTrue(fixture.access.model.selectionWrites.isEmpty)
        }
    }

    @MainActor
    func testExpectedWordUndoAndAutomaticRequestsNeverUseTheManualNoWorkException() async throws {
        for kind in 0..<3 {
            let fixture = try AXProfileFixture("")
            let operation = try fixture.prepare()
            let request = ConversionRequest(expectedWord: kind == 0 ? "ghbdtn" : nil,
                                            replacement: kind == 1 ? "original" : nil,
                                            useSelection: kind != 2, safetyLedger: operation.ledger)
            let result = await operation.converter.performWithEvidence(request)
            XCTAssertEqual(result.result, .unavailable)
            XCTAssertTrue(operation.ledger.hasProfileFault)
            XCTAssertEqual(fixture.snapshotReads, 1)
            XCTAssertEqual(fixture.access.model.textWrites, 0)
        }
    }

    @MainActor
    func testChangedMissingAndPermissionDeniedRepeatCannotBeReportedAsNoWork() async throws {
        for kind in 0..<4 {
            let fixture = try AXProfileFixture(" ")
            let operation = try fixture.prepare()
            fixture.duringRead = { _ in
                guard fixture.snapshotReads == 2 else { return }
                switch kind {
                case 0: fixture.access.model.value = "  "
                case 1: fixture.missingSnapshot = true
                case 2: fixture.access.model.currentSelection = NSRange(location: 0, length: 0)
                default: fixture.valid = false
                }
            }
            let result = await operation.converter.performWithEvidence(ConversionRequest(
                safetyLedger: operation.ledger, isValid: { fixture.valid }
            ))
            XCTAssertEqual(result.result, .unavailable)
            XCTAssertTrue(operation.ledger.hasProfileFault)
            XCTAssertEqual(operation.ledger.submissionCount, 0)
            XCTAssertTrue(fixture.access.model.selectionWrites.isEmpty)
        }
    }

    @MainActor
    func testSubmissionDuringRepeatCannotPassTheLastPureNoOwnedCheck() async throws {
        let fixture = try AXProfileFixture("")
        let operation = try fixture.prepare()
        fixture.duringRead = { _ in
            if fixture.snapshotReads == 2 {
                XCTAssertNotNil(operation.ledger.willSubmit(.selection, operation: operation.ledger.operation))
            }
        }
        let result = await operation.converter.performWithEvidence(ConversionRequest(safetyLedger: operation.ledger))
        XCTAssertEqual(result.result, .unavailable)
        XCTAssertTrue(operation.ledger.hasProfileFault)
        XCTAssertEqual(operation.ledger.submissionCount, 1)
        XCTAssertTrue(fixture.access.model.selectionWrites.isEmpty)
        XCTAssertEqual(try XCTUnwrap(operation.ledger.finishUsingRecordedCleanup(
            operation: operation.ledger.operation, text: .unknown, ordinaryRouteValid: true
        )).input, .recoveryRequired)
    }

    @MainActor
    func testUnavailableWriteAttributesWithARealWordRemainFault() async throws {
        let fixture = try AXProfileFixture("ghbdtn")
        let operation = try fixture.prepare()
        fixture.access.model.textIsSettable = false
        let result = await operation.converter.performWithEvidence(ConversionRequest(safetyLedger: operation.ledger))
        XCTAssertEqual(result.result, .unavailable)
        XCTAssertTrue(operation.ledger.hasProfileFault)
        XCTAssertEqual(operation.ledger.submissionCount, 0)
        XCTAssertEqual(fixture.access.model.textWrites, 0)
    }

    @MainActor
    func testCancellationInsideTheFreshRepeatCannotUseNoWorkException() async throws {
        let fixture = try AXProfileFixture("")
        let operation = try fixture.prepare()
        fixture.duringRead = { _ in
            if fixture.snapshotReads == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let result = await Task { @MainActor in
            await operation.converter.performWithEvidence(ConversionRequest(safetyLedger: operation.ledger))
        }.value
        XCTAssertEqual(result.result, .unavailable)
        XCTAssertTrue(operation.ledger.hasProfileFault)
        XCTAssertEqual(operation.ledger.submissionCount, 0)
        XCTAssertTrue(fixture.access.model.selectionWrites.isEmpty)
    }

    @MainActor
    func testActualProfileFailedRepeatRetainsQueueWithoutTISOrLegacyRelease() async throws {
        let editor = try AXProfileFixture("")
        let profile = try XCTUnwrap(editor.profile())
        let engine = AXTextConverter(access: editor.access, observationProfile: profile)
        let fixture = TrackedConverterFixture()
        fixture.profile = profile.binding
        fixture.mechanisms = [.accessibility]
        fixture.boundAXEngine = engine
        editor.duringRead = { _ in
            if editor.snapshotReads == 2 { editor.missingSnapshot = true }
        }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertTrue(fixture.converter.hasPendingRecovery)
        XCTAssertTrue(try XCTUnwrap(fixture.ledgers.first).hasProfileFault)
        XCTAssertEqual(fixture.adapters.first?.queued, 2)
        XCTAssertEqual(fixture.adapters.first?.delivered, 0)
        XCTAssertFalse(fixture.actions.contains("layout"))
        XCTAssertFalse(fixture.actions.contains("sound"))
        XCTAssertFalse(fixture.actions.contains("legacyRelease"))
        XCTAssertNil(fixture.undoStore.pendingUndo())
    }

    @MainActor
    func testActualProfileNoWorkThroughTrackedConverterDoesNotSwitchLayoutOrSignalSuccess() async throws {
        let editor = try AXProfileFixture("")
        let profile = try XCTUnwrap(editor.profile())
        let engine = AXTextConverter(access: editor.access, observationProfile: profile)
        let fixture = TrackedConverterFixture()
        fixture.profile = profile.binding
        fixture.mechanisms = [.accessibility]
        fixture.boundAXEngine = engine
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .failed, "No-work не публикует успешную замену")
        XCTAssertFalse(fixture.converter.hasPendingRecovery)
        XCTAssertFalse(try XCTUnwrap(fixture.ledgers.first).hasProfileFault)
        XCTAssertEqual(fixture.ledgers.first?.recordedCleanup, .noOwnedMutation)
        XCTAssertEqual(fixture.adapters.first?.delivered, 2)
        XCTAssertTrue(fixture.adapters.first?.corrections.isEmpty == true)
        XCTAssertFalse(fixture.actions.contains("mutation"))
        XCTAssertFalse(fixture.actions.contains("layout"))
        XCTAssertFalse(fixture.actions.contains("sound"))
        XCTAssertFalse(fixture.actions.contains("legacyRelease"))
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertTrue(fixture.clipboard.requests.isEmpty)
        XCTAssertTrue(editor.access.model.selectionWrites.isEmpty)
        XCTAssertEqual(editor.access.model.textWrites, 0)
    }
}
