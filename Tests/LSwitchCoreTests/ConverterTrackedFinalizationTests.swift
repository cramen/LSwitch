import Foundation
@testable import LSwitchCore
import XCTest

final class ConverterTrackedFinalizationTests: XCTestCase {
    @MainActor
    func testDiagnosticInvalidationAfterPreparationRefusesAllFinalEffects() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        let diagnostics = ConversionDiagnostics(bundleID: "com.example.TextEdit", triggerTimestamp: nil,
                                                attempt: 1, automatic: false, now: { 10 }, emit: { sample in
            if sample.phase == .textConfirmed { fixture.safe = false }
        })
        let result = await fixture.converter.trigger(diagnostics: diagnostics)
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertEqual(fixture.ledgers.first?.decision?.input, .replayAuthorized)
        XCTAssertEqual(fixture.ledgers.first?.currentInputDisposition, .recoveryRequired)
        XCTAssertFalse(fixture.actions.contains("layout"))
        XCTAssertFalse(fixture.actions.contains("commit"))
        XCTAssertFalse(fixture.actions.contains("sound"))
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertEqual(fixture.adapters.first?.retainedClaim?.owner, .recovery)
    }

    @MainActor
    func testRouteCallbackCannotLeaveStaleContextValidForTIS() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility)
        fixture.configureAdapter = { adapter in
            adapter.onRouteCheck = {
                if fixture.actions.last == "prepareDelivery" { fixture.safe = false }
            }
        }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertFalse(fixture.actions.contains("layout"))
        XCTAssertFalse(fixture.actions.contains("sound"))
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertEqual(fixture.adapters.first?.queued, 2)
    }

    @MainActor
    func testAlreadyTargetReadbackCannotInvalidateContextAndThenTriggerSwitch() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility, original: "руддщ", converted: "hello")
        var reads = 0
        fixture.onLayoutRead = {
            reads += 1
            if reads == 2 { fixture.safe = false; fixture.layout = .russian }
        }
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(fixture.actions.contains("layout"))
        XCTAssertFalse(fixture.actions.contains("commit"))
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertEqual(fixture.adapters.first?.retentions, 1)
    }

    @MainActor
    func testCanonicallyEquivalentButDifferentUTF16UndoReceiptIsNotAccepted() async {
        let fixture = TrackedConverterFixture()
        fixture.succeed(fixture.accessibility, original: "e\u{301}", converted: "у\u{301}")
        _ = await fixture.converter.trigger()
        fixture.succeed(fixture.accessibility, original: "у\u{301}", converted: "\u{00e9}")
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertEqual(fixture.actions.filter { $0 == "layout" }.count, 1)
        XCTAssertEqual(fixture.actions.filter { $0 == "sound" }.count, 1)
        XCTAssertEqual(fixture.adapters.last?.delivered, 0)
        XCTAssertNil(fixture.undoStore.pendingUndo())
    }
}
