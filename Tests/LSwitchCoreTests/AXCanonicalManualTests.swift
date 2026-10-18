#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class AXCanonicalManualTests: XCTestCase {
    @MainActor
    func testCanonicalManualDelegatesOuterChecksAndAlwaysProducesIndependentDocumentTarget() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let access = AXCanonicalManualAccess(fixture.editor.access)
        let engine = AXTextConverter(access: access, observationProfile: fixture.profile)
        let result = await engine.perform(try fixture.manualRequest())
        guard case .success(let receipt) = result else { return XCTFail("Нужна здоровая manual конвертация") }
        XCTAssertEqual(access.documentReads, 0, "Transient nil generic identity не убирает profile anchor")
        XCTAssertEqual(access.focusReads, 1)
        XCTAssertEqual(access.protectionReads, 1)
        XCTAssertEqual(access.automaticReads, 0)
        XCTAssertNotNil(receipt.profileTarget)
        XCTAssertEqual(receipt.targetIsCurrent?(), true)
        XCTAssertTrue(receipt.profileTarget?.hasFinalSelection == true)
        XCTAssertTrue(fixture.editor.access.model.value.utf16.elementsEqual("привет ".utf16))
    }

    @MainActor
    func testCustomManualAndAutomaticRequestsKeepGenericOuterChecksAndLoseTypedReceipt() async throws {
        for automatic in [false, true] {
            let fixture = try AXCombinedProfileFixture()
            await fixture.arm()
            let access = AXCanonicalManualAccess(fixture.editor.access)
            let request: ConversionRequest
            if automatic { request = fixture.request } else {
                request = try fixture.manualRequest().checkingTarget { true }
            }
            let engine = AXTextConverter(access: access, observationProfile: fixture.profile)
            let result = await engine.perform(request)
            guard case .success(let receipt) = result else { return XCTFail("Контрольный путь должен работать") }
            XCTAssertGreaterThan(access.focusReads, 1)
            XCTAssertGreaterThan(access.protectionReads, 1)
            XCTAssertNil(receipt.profileTarget)
            if automatic { XCTAssertGreaterThan(access.automaticReads, 0) } else {
                XCTAssertGreaterThan(access.documentReads, 0)
            }
        }
    }

    @MainActor
    func testDocumentSwitchAfterOwnSelectionBlocksTextAndFurtherSetterOnCanonicalManual() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let editor = fixture.editor
        editor.access.afterWrite = { [weak editor] in editor?.document = "fixture:other-document" }
        let access = AXCanonicalManualAccess(editor.access)
        let engine = AXTextConverter(access: access, observationProfile: fixture.profile)
        let result = await engine.perform(try fixture.manualRequest())
        if case .success = result { XCTFail("Нельзя подтвердить чужой документ") }
        XCTAssertEqual(editor.access.model.selectionWrites.count, 1)
        XCTAssertEqual(editor.access.model.textWrites, 0)
        XCTAssertEqual(access.documentReads, 0)
        XCTAssertTrue(fixture.ledger.hasProfileFault)
    }

    @MainActor
    func testReceiptRemainsFreshAfterLayoutSwitchAndLedgerFinishButRejectsNewDocument() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let engine = try XCTUnwrap(fixture.session.boundAXEngine)
        let result = await engine.perform(try fixture.manualRequest())
        guard case .success(let receipt) = result else { return XCTFail("Нужен receipt") }
        XCTAssertNotNil(fixture.ledger.finishUsingRecordedCleanup(
            operation: fixture.ledger.operation, text: .confirmed, ordinaryRouteValid: true))
        fixture.editor.activeSource = .init(identifier: "com.apple.keylayout.Russian", isKeyboardLayout: true)
        XCTAssertEqual(receipt.targetIsCurrent?(), true)
        XCTAssertFalse(fixture.profile.isCurrent(ledger: fixture.ledger))
        fixture.editor.document = "fixture:reused-tab"
        XCTAssertEqual(receipt.targetIsCurrent?(), false)
        let custom = receipt.checkingTarget { true }
        XCTAssertNil(custom.profileTarget)
    }
}
#endif
