#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class AXCombinedProfileTests: XCTestCase {
    @MainActor
    func testCanonicalClosingFocusChecksMetadataReentryBeforePayload() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let model = fixture.editor.access.model
        let before = model.focusReads
        XCTAssertTrue(fixture.bind())
        XCTAssertEqual(model.focusReads - before, 1)
        fixture.controls.onContext = { [weak model] in
            model?.changeFocusAfterSelection = true
            model?.selectionWrites.append(NSRange(location: 0, length: 0))
        }
        XCTAssertNil(fixture.profile.read(expected: nil, ledger: fixture.ledger))
        XCTAssertEqual(model.textReads, 0)
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
        XCTAssertTrue(fixture.ledger.hasProfileFault)
    }

    @MainActor
    func testCanonicalProfileChecksTargetOnceWithoutCallingFullSessionContextAgain() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let fullChecks = fixture.controls.fullTargetChecks
        let contextReads = fixture.controls.contextReads
        XCTAssertTrue(fixture.bind())
        XCTAssertEqual(fixture.controls.fullTargetChecks, fullChecks)
        XCTAssertEqual(fixture.controls.contextReads, contextReads + 1)
        XCTAssertEqual(fixture.controls.foregroundReads, 2)
        XCTAssertNotNil(fixture.profile.read(expected: nil, ledger: fixture.ledger))
        XCTAssertEqual(fixture.controls.fullTargetChecks, fullChecks)
        XCTAssertEqual(fixture.editor.snapshotReads, 1)
        XCTAssertEqual(fixture.editor.access.model.textReads, 1)
        XCTAssertEqual(fixture.profile.diagnosticReport.foreground.count, UInt64(fixture.controls.foregroundReads))
    }

    @MainActor
    func testUnknownOrForeignForegroundRefusesDespiteMatchingAXFocusBeforePayload() async throws {
        for foreground: Int32? in [nil, 0] {
            let fixture = try AXCombinedProfileFixture()
            await fixture.arm()
            fixture.controls.foreground = foreground
            XCTAssertFalse(fixture.bind())
            XCTAssertTrue(fixture.ledger.hasProfileFault)
            XCTAssertEqual(fixture.editor.snapshotReads, 0)
            XCTAssertEqual(fixture.editor.access.model.textReads, 0)
            XCTAssertTrue(fixture.editor.access.model.selectionWrites.isEmpty)
        }
    }

    @MainActor
    func testForegroundChangeDuringAXContextReadIsCaughtByClosingForegroundRead() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let controls = fixture.controls
        controls.onContext = { [weak controls] in controls?.foreground = nil }
        XCTAssertFalse(fixture.bind())
        XCTAssertEqual(controls.foregroundReads, 2)
        XCTAssertEqual(fixture.editor.access.model.textReads, 0)
        XCTAssertTrue(fixture.ledger.hasProfileFault)
    }

    @MainActor
    func testHostCallbackTargetChangeIsValidatedAfterOpeningAndBeforeAnyPayload() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let editor = fixture.editor
        fixture.controls.hostSafety = { [weak editor] in editor?.document = "fixture:changed"; return true }
        XCTAssertFalse(fixture.bind())
        XCTAssertEqual(fixture.editor.access.model.textReads, 0)
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
    }

    @MainActor
    func testDocumentChangeInsideSnapshotStillStopsBeforeItsFirstTextRead() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        XCTAssertTrue(fixture.bind())
        let editor = fixture.editor
        editor.duringRead = { [weak editor] _ in editor?.document = "fixture:changed" }
        XCTAssertNil(fixture.profile.read(expected: nil, ledger: fixture.ledger))
        XCTAssertEqual(editor.snapshotReads, 1)
        XCTAssertEqual(editor.access.model.textReads, 0)
        XCTAssertTrue(fixture.ledger.hasProfileFault)
    }

    @MainActor
    func testSourceOrProtectionChangeInsideCanonicalContextReadStopsBeforePayload() async throws {
        for changesSource in [true, false] {
            let fixture = try AXCombinedProfileFixture()
            await fixture.arm()
            let editor = fixture.editor
            fixture.controls.onContext = { [weak editor] in
                if changesSource {
                    editor?.activeSource = .init(identifier: "com.apple.keylayout.Russian", isKeyboardLayout: true)
                } else {
                    editor?.access.model.protected = true
                }
            }
            XCTAssertFalse(fixture.bind())
            XCTAssertTrue(fixture.ledger.hasProfileFault)
            XCTAssertEqual(editor.access.model.textReads, 0)
            XCTAssertEqual(editor.access.model.textWrites, 0)
            XCTAssertTrue(editor.access.model.selectionWrites.isEmpty)
        }
    }

    @MainActor
    func testAdditionalRequestGuardLosesCapabilityAndStopsPayloadWhenItBecomesFalse() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let controls = fixture.controls
        let wrapped = fixture.request.checkingTarget { controls.additionalValid }
        XCTAssertNil(wrapped.profileValidation)
        fixture.editor.duringRead = { _ in controls.additionalValid = false }
        let engine = try XCTUnwrap(fixture.session.boundAXEngine)
        let result = await engine.perform(wrapped)
        if case .success = result { XCTFail("Дополнительный validator не может быть пропущен") }
        XCTAssertGreaterThan(fixture.controls.fullTargetChecks, 2)
        XCTAssertEqual(fixture.editor.access.model.textReads, 0)
        XCTAssertTrue(fixture.editor.access.model.selectionWrites.isEmpty)
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
    }

    @MainActor
    func testBoundCapabilityCannotBeDowngradedOrReplacedByAnotherOperation() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        XCTAssertTrue(fixture.bind())
        XCTAssertFalse(fixture.profile.bind(to: fixture.editor.access.model.element, ledger: fixture.ledger,
                                           isValid: { true }))
        let other = try AXCombinedProfileFixture()
        XCTAssertFalse(fixture.profile.bind(to: fixture.editor.access.model.element, ledger: fixture.ledger,
                                           isValid: { true }, validation: other.capability))
        XCTAssertEqual(fixture.editor.snapshotReads, 0)
    }

    @MainActor
    func testHealthyRealAXEngineKeepsProfileEvidenceAndExactResultWithoutFinalizingLedger() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let engine = try XCTUnwrap(fixture.session.boundAXEngine)
        let result = await engine.perform(fixture.request)
        guard case .success(let receipt) = result else { return XCTFail("Здоровая модель должна конвертироваться") }
        XCTAssertEqual(receipt.original, "ghbdtn")
        XCTAssertEqual(receipt.converted, "привет")
        XCTAssertTrue(fixture.editor.access.model.value.utf16.elementsEqual("привет ".utf16))
        XCTAssertTrue(fixture.ledger.hasObservedProfileFinalState)
        XCTAssertNil(fixture.ledger.decision)
        XCTAssertFalse(fixture.ledger.hasProfileFault)
        XCTAssertGreaterThan(fixture.profile.diagnosticReport.foreground.count, 0)
    }
}
#endif
