@testable import LSwitchCore
import XCTest

@MainActor
final class ConverterUnicodeRoutingTests: XCTestCase {
    func testSelectedUnicodeNeverFallsBackForAnyFailure() async {
        for result: ConversionResult in [.unavailable, .blocked, .failed] {
            let fixture = ConverterFixture()
            fixture.clipboardPreferred = true
            fixture.unicodePreferred = true
            fixture.unicodeEngine.result = result
            fixture.succeed(fixture.axEngine)
            fixture.succeed(fixture.clipboardEngine)
            let outcome = await fixture.converter.trigger()
            XCTAssertEqual(outcome, result == .blocked ? .blockedBySafety : .failed)
            XCTAssertEqual(fixture.unicodeEngine.requests.count, 1)
            XCTAssertTrue(fixture.axEngine.requests.isEmpty)
            XCTAssertTrue(fixture.clipboardEngine.requests.isEmpty)
            XCTAssertTrue(fixture.switchedTo.isEmpty)
            XCTAssertFalse(fixture.holdActive)
        }
    }

    func testUnicodeReceiptDrivesExactInverseWithoutNativeUndo() async {
        let fixture = ConverterFixture()
        fixture.unicodePreferred = true
        fixture.unicodeEngine.result = .success(
            .init(original: "ghbdtn", converted: "привет", trailingText: " ")
        )
        let converted = await fixture.converter.trigger(expectedWord: "ghbdtn", trailingText: " ", allowUndo: false)
        XCTAssertEqual(converted, .converted(original: "ghbdtn", converted: "привет"))
        fixture.unicodeEngine.handler = { request in
            XCTAssertEqual(request.expectedWord, "привет")
            XCTAssertEqual(request.replacement, "ghbdtn")
            XCTAssertEqual(request.trailingText, " ")
            XCTAssertFalse(request.useSelection)
            return .success(.init(original: "привет", converted: "ghbdtn", trailingText: " "))
        }
        let undone = await fixture.converter.trigger()
        XCTAssertEqual(undone, .undone)
        XCTAssertEqual(fixture.unicodeEngine.requests.count, 2)
        XCTAssertTrue(fixture.axEngine.requests.isEmpty)
        XCTAssertTrue(fixture.clipboardEngine.requests.isEmpty)
        XCTAssertEqual(fixture.switchedTo, [.russian, .english])
    }

    func testChangedDocumentRejectsUnicodeUndoBeforeAnotherPacket() async {
        let fixture = ConverterFixture()
        fixture.unicodePreferred = true
        var currentDocument = true
        fixture.unicodeEngine.result = .success(.init(
            original: "ghbdtn", converted: "привет", targetIsCurrent: { currentDocument }
        ))
        _ = await fixture.converter.trigger()
        currentDocument = false
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .blockedBySafety)
        XCTAssertEqual(fixture.unicodeEngine.requests.count, 1)
        XCTAssertNil(fixture.undoStore.pendingUndo())
    }
}
