@testable import LSwitchCore
import XCTest

final class ConverterInputHoldTests: XCTestCase {
    @MainActor
    func testInputIsReleasedOnlyAfterConfirmedLayoutChange() async {
        let fixture = ConverterFixture()
        fixture.axEngine.handler = { request in
            XCTAssertTrue(fixture.holdActive, "Ввод удерживается до первого чтения редактора движком")
            XCTAssertTrue(request.beginMutation())
            XCTAssertTrue(request.beginMutation())
            XCTAssertTrue(fixture.holdActive)
            return .success(ConversionReceipt(original: "ghbdtn", converted: "привет"))
        }
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(fixture.actions, ["hold", "layout", "record", "sound", "release"])
        XCTAssertFalse(fixture.holdActive)
    }

    @MainActor
    func testFailedMutationReleasesInputWithoutSwitchingLayout() async {
        let fixture = ConverterFixture()
        fixture.axEngine.handler = { request in
            XCTAssertTrue(request.beginMutation())
            return .failed
        }
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(fixture.actions, ["hold", "release"])
        XCTAssertFalse(fixture.holdActive)
    }

    @MainActor
    func testUnavailableHoldPreventsMutation() async {
        let fixture = ConverterFixture()
        fixture.holdAllowed = false
        fixture.axEngine.handler = { request in
            XCTAssertFalse(request.beginMutation())
            return .blocked
        }
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .blockedBySafety)
        XCTAssertEqual(fixture.actions, ["hold"])
    }

    @MainActor
    func testExpiredHoldInvalidatesRequestAndDoesNotSwitchLayout() async {
        let fixture = ConverterFixture()
        fixture.axEngine.handler = { request in
            XCTAssertTrue(request.beginMutation())
            fixture.holdActive = false
            XCTAssertFalse(request.isValid())
            XCTAssertTrue(request.canCleanup())
            return .success(ConversionReceipt(original: "ghbdtn", converted: "привет"))
        }
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .blockedBySafety)
        XCTAssertEqual(fixture.actions, ["hold", "release"])
    }
}
