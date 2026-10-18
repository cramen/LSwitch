#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class AXEffectiveRequestTests: XCTestCase {
    @MainActor
    func testAutomaticEffectiveContextGuardStopsSnapshotBeforePayloadWhenContextChanges() async throws {
        let contexts: [AutomaticTextContext] = [
            .documentProse(document: "file:///fixture/a.txt"),
            .source(language: .swift, document: "file:///fixture/a.swift", characterCount: 10)
        ]
        for context in contexts {
            let fixture = try AXCombinedProfileFixture()
            await fixture.arm()
            let model = fixture.editor.access.model
            model.value = "// ghbdtn "
            model.currentSelection = NSRange(location: model.value.utf16.count, length: 0)
            model.documentContext = context
            fixture.editor.duringRead = { [weak model] _ in model?.documentContext = .unknown }
            let engine = try XCTUnwrap(fixture.session.boundAXEngine)
            let result = await engine.perform(fixture.request)
            if case .success = result { XCTFail("Effective context wrapper нельзя обходить") }
            XCTAssertEqual(fixture.editor.snapshotReads, 1)
            XCTAssertEqual(model.textReads, 0)
            XCTAssertTrue(model.selectionWrites.isEmpty)
            XCTAssertEqual(model.textWrites, 0)
            XCTAssertEqual(fixture.ledger.submissionCount, 0)
            XCTAssertTrue(fixture.ledger.hasProfileFault)
        }
    }
}
#endif
