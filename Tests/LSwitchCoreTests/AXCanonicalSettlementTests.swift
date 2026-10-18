#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class AXCanonicalSettlementTests: XCTestCase {
    @MainActor
    func testSecondStableReadAcceptsPendingCommandWithoutThirdSnapshot() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let mutation = AXMutationSafety(request: try fixture.manualRequest(), receiverContract: nil,
                                        profile: fixture.profile)
        let model = fixture.editor.access.model
        let range = NSRange(location: 0, length: 6)
        XCTAssertTrue(mutation.bind(to: model.element))
        XCTAssertTrue(mutation.writeCanonicalSelection(range, in: model.element, access: fixture.editor.access))
        var pauses = 0
        let settled = await mutation.settleCanonical(.selectedRangeSettled, expected: .init(model.value, range)) {
            pauses += 1
            XCTAssertTrue(fixture.ledger.hasUnacceptedSubmissions)
            XCTAssertEqual(fixture.editor.snapshotReads, pauses - 1)
            await Task.yield()
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(pauses, 2)
        XCTAssertEqual(fixture.editor.snapshotReads, 2)
        XCTAssertFalse(fixture.ledger.hasUnacceptedSubmissions)
    }

    @MainActor
    func testContextLossDuringEitherPausePreventsAcceptanceAndFurtherWrites() async throws {
        for failingPause in [1, 2] {
            let fixture = try AXCombinedProfileFixture()
            await fixture.arm()
            let mutation = AXMutationSafety(request: try fixture.manualRequest(), receiverContract: nil,
                                            profile: fixture.profile)
            let model = fixture.editor.access.model
            let range = NSRange(location: 0, length: 6)
            XCTAssertTrue(mutation.bind(to: model.element))
            XCTAssertTrue(mutation.writeCanonicalSelection(range, in: model.element, access: fixture.editor.access))
            var pauses = 0
            let settled = await mutation.settleCanonical(.selectedRangeSettled, expected: .init(model.value, range)) {
                pauses += 1
                await Task.yield()
                if pauses == failingPause { fixture.editor.document = "fixture:foreign" }
            }
            XCTAssertFalse(settled)
            XCTAssertTrue(fixture.ledger.hasUnacceptedSubmissions)
            XCTAssertTrue(fixture.ledger.hasProfileFault)
            XCTAssertFalse(mutation.writeCanonicalText("привет", in: model.element, access: fixture.editor.access))
            XCTAssertEqual(model.textWrites, 0)
            XCTAssertEqual(model.selectionWrites.count, 1)
        }
    }

    @MainActor
    func testSecondReadMismatchCannotBeHealedByLaterMatchingText() async throws {
        let fixture = try AXCombinedProfileFixture()
        await fixture.arm()
        let mutation = AXMutationSafety(request: try fixture.manualRequest(), receiverContract: nil,
                                        profile: fixture.profile)
        let model = fixture.editor.access.model
        let original = model.value
        let range = NSRange(location: 0, length: 6)
        XCTAssertTrue(mutation.bind(to: model.element))
        XCTAssertTrue(mutation.writeCanonicalSelection(range, in: model.element, access: fixture.editor.access))
        var pauses = 0
        let settled = await mutation.settleCanonical(.selectedRangeSettled, expected: .init(original, range)) {
            pauses += 1
            if pauses == 2 { model.value = "foreign" }
        }
        XCTAssertFalse(settled)
        model.value = original
        XCTAssertNil(mutation.profileRead(.init(original, range)))
        XCTAssertTrue(fixture.ledger.hasProfileFault)
        XCTAssertTrue(fixture.ledger.hasUnacceptedSubmissions)
    }
}
#endif
