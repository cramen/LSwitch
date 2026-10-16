import ApplicationServices
import Foundation
@testable import LSwitchCore
import XCTest

final class AXProfileTests: XCTestCase {
    func testProfileSnapshotRejectsNegativeAndSurrogateInteriorWithoutOverflow() {
        let ranges = [NSRange(location: Int.min, length: 0), NSRange(location: 0, length: -1),
                      NSRange(location: 1, length: 0), NSRange(location: 0, length: 1)]
        for range in ranges {
            XCTAssertFalse(AXProfileSnapshot(text: "😀", selection: range, characterCount: 2).isComplete)
        }
        XCTAssertTrue(AXProfileSnapshot(text: "😀", selection: NSRange(location: 2, length: 0),
                                        characterCount: 2).isComplete)
    }

    @MainActor
    func testObservedConversionAndExactNBSPInverseDoNotInventReceiverCompletion() async throws {
        let fixture = try AXProfileFixture("😀 ghbdtn\u{00a0}")
        let first = try fixture.prepare()
        let result = await first.converter.performWithEvidence(fixture.request(first.ledger))
        guard case .success(let receipt) = result.result else { return XCTFail("Нужен профильный результат") }
        XCTAssertEqual(receipt.trailingText, "\u{00a0}")
        XCTAssertEqual(first.ledger.submissionCount, 3)
        XCTAssertTrue(first.ledger.hasUnresolvedSubmissions, "ObservedUnderProfile не является ACK")
        XCTAssertFalse(first.ledger.hasUnacceptedSubmissions)
        XCTAssertTrue(first.ledger.hasObservedProfileFinalState)
        XCTAssertNil(first.ledger.decision, "Финализирует внешний владелец очереди")
        let decision = try XCTUnwrap(first.ledger.finishUsingRecordedCleanup(
            operation: first.ledger.operation, text: .confirmed, ordinaryRouteValid: true
        ))
        XCTAssertEqual(decision.verificationBasis, .observedUnderProfile)
        XCTAssertTrue(decision.permitsConfirmedResult)
        let inverse = try fixture.prepare()
        let undone = await inverse.converter.performWithEvidence(fixture.request(inverse.ledger, replacement: "ghbdtn"))
        guard case .success = undone.result else { return XCTFail("Нужен точный inverse") }
        XCTAssertTrue(fixture.access.model.value.utf16.elementsEqual("😀 ghbdtn\u{00a0}".utf16))
        XCTAssertEqual(fixture.access.model.currentSelection, NSRange(location: 10, length: 0))
    }

    @MainActor
    func testProfileAndLedgerMustShareTheSameCapturedIdentityBeforeAnySetter() async throws {
        let fixture = try AXProfileFixture()
        let first = try fixture.prepare()
        let second = try fixture.prepare()
        let result = await first.converter.performWithEvidence(fixture.request(second.ledger))
        XCTAssertEqual(result.result, .blocked)
        XCTAssertEqual(second.ledger.submissionCount, 0)
        XCTAssertTrue(fixture.access.model.selectionWrites.isEmpty)
    }

    @MainActor
    func testUnsupportedVersionBuildRoleAndSystemCannotPrepareProfile() throws {
        let fixture = try AXProfileFixture()
        fixture.applicationVersion = "1.20"
        XCTAssertNil(fixture.profile())
        fixture.applicationVersion = "1.19"
        fixture.applicationBuild = "405"
        XCTAssertNil(fixture.profile())
        fixture.applicationBuild = "404"
        fixture.systemBuild = "23F80"
        XCTAssertNil(fixture.profile())
        fixture.systemBuild = "23F79"
        fixture.role = kAXTextFieldRole
        XCTAssertNil(fixture.profile())
        XCTAssertEqual(fixture.snapshotReads, 0)
    }

    @MainActor
    func testPersistentIncoherenceAfterSelectionCannotWriteTextOrRestoreSelection() async throws {
        for missing in [false, true] {
            let fixture = try AXProfileFixture()
            let operation = try fixture.prepare()
            fixture.access.afterWrite = {
                if missing { fixture.missingSnapshot = true } else { fixture.countOverride = 999 }
            }
            let result = await operation.converter.performWithEvidence(fixture.request(operation.ledger))
            XCTAssertEqual(result.result, .failed)
            XCTAssertTrue(operation.ledger.hasProfileFault)
            XCTAssertEqual(fixture.access.model.selectionWrites.count, 1)
            XCTAssertEqual(fixture.access.model.textWrites, 0)
            fixture.countOverride = nil
            fixture.missingSnapshot = false
            XCTAssertFalse(operation.profile.isCurrent(ledger: operation.ledger))
            XCTAssertNil(operation.ledger.willSubmitCleanup(.restoreSelection, operation: operation.ledger.operation))
        }
    }

    @MainActor
    func testErrorAndLateSetterNeverReceiveASecondSetterOrReviveReceipt() async throws {
        let fixture = try AXProfileFixture()
        let operation = try fixture.prepare()
        fixture.access.firstSelectionStatus = .cannotComplete
        fixture.access.deferFirstSelection = true
        let result = await operation.converter.performWithEvidence(fixture.request(operation.ledger))
        XCTAssertEqual(result.result, .failed)
        XCTAssertEqual(fixture.access.replies, [.cannotComplete])
        fixture.access.applyDelayedSelection()
        XCTAssertFalse(operation.profile.isCurrent(ledger: operation.ledger))
        XCTAssertEqual(fixture.access.model.selectionWrites.count, 1)
        XCTAssertEqual(fixture.access.model.textWrites, 0)
        XCTAssertEqual(try XCTUnwrap(operation.ledger.finishUsingRecordedCleanup(
            operation: operation.ledger.operation, text: .unknown, ordinaryRouteValid: true
        )).input, .recoveryRequired)
    }

    @MainActor
    func testNoOpSelectionCannotUseLaterMatchingReadToContinue() async throws {
        let fixture = try AXProfileFixture()
        let operation = try fixture.prepare()
        fixture.access.deferFirstSelection = true
        let result = await operation.converter.performWithEvidence(fixture.request(operation.ledger))
        XCTAssertEqual(result.result, .failed)
        fixture.access.applyDelayedSelection()
        XCTAssertTrue(operation.ledger.hasProfileFault)
        XCTAssertEqual(fixture.access.model.textWrites, 0)
        XCTAssertEqual(fixture.access.model.selectionWrites.count, 1)
    }

    @MainActor
    func testDocumentWindowAndProcessBirthChangesAreStickyBeforeNextSetter() async throws {
        for field in 0..<3 {
            let fixture = try AXProfileFixture()
            let operation = try fixture.prepare()
            let replacementProcess = try XCTUnwrap(RecoveryProcessIdentity(
                processID: 100, birthSeconds: 2, birthMicroseconds: 0
            ))
            fixture.access.afterWrite = {
                switch field {
                case 0: fixture.document = "fixture:document-b"
                case 1: fixture.window = AXUIElementCreateApplication(201)
                default: fixture.process = replacementProcess
                }
            }
            let result = await operation.converter.performWithEvidence(fixture.request(operation.ledger))
            XCTAssertEqual(result.result, .failed)
            XCTAssertEqual(operation.ledger.profileFault, .contextChanged)
            XCTAssertEqual(fixture.access.model.selectionWrites.count, 1)
            XCTAssertEqual(fixture.access.model.textWrites, 0)
        }
    }

    @MainActor
    func testPrivacyDenialInsideSnapshotCannotBeRevivedByABA() async throws {
        let fixture = try AXProfileFixture()
        let operation = try fixture.prepare()
        fixture.duringRead = { canRead in
            fixture.access.model.protected = true
            XCTAssertFalse(canRead())
            fixture.access.model.protected = false
        }
        let result = await operation.converter.performWithEvidence(fixture.request(operation.ledger))
        XCTAssertEqual(result.result, .unavailable)
        XCTAssertTrue(operation.ledger.hasProfileFault)
        XCTAssertTrue(fixture.access.model.selectionWrites.isEmpty)
        XCTAssertEqual(fixture.access.model.textReads, 0, "Даже initial snapshot проходит профильный read guard")
    }

    @MainActor
    func testRequestInvalidationInsideFinalSnapshotRejectsReceipt() async throws {
        let fixture = try AXProfileFixture()
        let operation = try fixture.prepare()
        fixture.duringRead = { _ in
            if fixture.access.model.selectionWrites.count == 2 { fixture.valid = false }
        }
        let result = await operation.converter.performWithEvidence(fixture.request(operation.ledger))
        XCTAssertEqual(result.result, .failed)
        XCTAssertTrue(operation.ledger.hasProfileFault)
        XCTAssertFalse(operation.ledger.hasObservedProfileFinalState)
        XCTAssertEqual(fixture.access.model.textWrites, 1)
        XCTAssertEqual(fixture.access.model.selectionWrites.count, 2)
    }

    @MainActor
    func testCancellationAfterSetterKeepsCleanupReadOnly() async throws {
        let fixture = try AXProfileFixture()
        let operation = try fixture.prepare()
        fixture.access.afterWrite = { withUnsafeCurrentTask { $0?.cancel() } }
        let result = await Task { @MainActor in
            await operation.converter.performWithEvidence(fixture.request(operation.ledger))
        }.value
        XCTAssertEqual(result.result, .blocked)
        XCTAssertTrue(operation.ledger.hasProfileFault)
        XCTAssertEqual(fixture.access.model.selectionWrites.count, 1)
        XCTAssertEqual(fixture.access.model.textWrites, 0)
    }

    @MainActor
    func testTextFailureAndNoOpForbidFinalCaretSetter() async throws {
        for noOp in [false, true] {
            let fixture = try AXProfileFixture()
            let operation = try fixture.prepare()
            if noOp { fixture.access.model.ignoreTextWrite = true } else { fixture.access.textStatus = .failure }
            let result = await operation.converter.performWithEvidence(fixture.request(operation.ledger))
            XCTAssertEqual(result.result, .failed)
            XCTAssertTrue(operation.ledger.hasProfileFault)
            XCTAssertEqual(fixture.access.model.textWrites, 1)
            XCTAssertEqual(fixture.access.model.selectionWrites.count, 1)
            XCTAssertEqual(result.cleanup, .recoveryUnconfirmed)
        }
    }

    @MainActor
    func testCanonicalEquivalentForeignTextFailsExactProfileBeforeAnotherSetter() async throws {
        let fixture = try AXProfileFixture("e\u{301}\u{327} ghbdtn ")
        let operation = try fixture.prepare()
        fixture.access.afterWrite = { fixture.access.model.value = "e\u{327}\u{301} ghbdtn " }
        let result = await operation.converter.performWithEvidence(fixture.request(operation.ledger))
        XCTAssertEqual(result.result, .failed)
        XCTAssertEqual(operation.ledger.profileFault, .snapshotMismatch)
        XCTAssertEqual(fixture.access.model.selectionWrites.count, 1)
        XCTAssertEqual(fixture.access.model.textWrites, 0)
    }

    @MainActor
    func testIMEAndChangedDirectInputSourceCannotUseProfile() async throws {
        let fixture = try AXProfileFixture()
        fixture.activeSource = nil
        XCTAssertNil(fixture.profile())
        XCTAssertEqual(fixture.snapshotReads, 0)
        fixture.activeSource = UnicodeInputSource(identifier: "com.apple.keylayout.ABC", isKeyboardLayout: true)
        let operation = try fixture.prepare()
        fixture.access.afterWrite = {
            fixture.activeSource = UnicodeInputSource(identifier: "com.apple.keylayout.Russian", isKeyboardLayout: true)
        }
        let result = await operation.converter.performWithEvidence(fixture.request(operation.ledger))
        XCTAssertEqual(result.result, .failed)
        XCTAssertEqual(operation.ledger.profileFault, .contextChanged)
        XCTAssertEqual(fixture.access.model.selectionWrites.count, 1)
        XCTAssertEqual(fixture.access.model.textWrites, 0)
    }

    @MainActor
    func testOptInProfileCannotAccidentallyRunThroughLegacyWithoutLedger() async throws {
        let fixture = try AXProfileFixture()
        let operation = try fixture.prepare()
        let result = await operation.converter.performWithEvidence(ConversionRequest())
        XCTAssertEqual(result.result, .blocked)
        XCTAssertTrue(fixture.access.model.selectionWrites.isEmpty)
        XCTAssertEqual(fixture.access.model.textReads, 0)
    }

    @MainActor
    func testInvalidPreflightCountBecomesStickyFaultWithoutPayloadOrSetter() async throws {
        for count in [-1, Int.max, AXProfileSnapshot.maximumUTF16Units + 1] {
            let fixture = try AXProfileFixture()
            fixture.countOverride = count
            let operation = try fixture.prepare()
            let result = await operation.converter.performWithEvidence(fixture.request(operation.ledger))
            XCTAssertEqual(result.result, .unavailable)
            XCTAssertEqual(operation.ledger.profileFault, .snapshotUnavailable)
            XCTAssertEqual(fixture.access.model.textReads, 0)
            XCTAssertEqual(operation.ledger.submissionCount, 0)
            XCTAssertTrue(fixture.access.model.selectionWrites.isEmpty)
            fixture.countOverride = nil
            XCTAssertFalse(operation.profile.isCurrent(ledger: operation.ledger))
        }
    }
}
