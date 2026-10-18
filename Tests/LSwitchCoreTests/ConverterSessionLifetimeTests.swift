import Foundation
@testable import LSwitchCore
import XCTest

final class ConverterSessionLifetimeTests: XCTestCase {
    @MainActor
    func testSuccessfulProfileDoesNotKeepSessionOrAdapterAliveThroughItsStoredValidityClosure() async throws {
        let editor = try AXProfileFixture()
        let profile = try XCTUnwrap(editor.profile())
        let fixture = TrackedConverterFixture()
        fixture.profile = profile.binding
        fixture.mechanisms = [.accessibility]
        fixture.boundAXEngine = AXTextConverter(access: editor.access, observationProfile: profile)
        let result = await fixture.converter.trigger(expectedWord: "ghbdtn", trailingText: " ", allowUndo: false)
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertFalse(fixture.owner.isOccupied)
        weak var session = fixture.sessions.first
        weak var adapter = fixture.adapters.first
        XCTAssertNotNil(session)
        XCTAssertNotNil(adapter)
        fixture.sessions.removeAll()
        fixture.adapters.removeAll()
        XCTAssertNil(session, "Owner уже отпустил операцию; profile callback не должен создавать цикл")
        XCTAssertNil(adapter)
        XCTAssertNotNil(fixture.boundAXEngine, "Engine и профиль намеренно продолжают жить")
        XCTAssertNotNil(fixture.undoStore.pendingUndo())
        XCTAssertFalse(profile.isCurrent(ledger: try XCTUnwrap(fixture.ledgers.first)))
    }

    @MainActor
    func testStoredRequestGuardsRefuseAfterSuccessfulSessionReleaseWithoutRetainingTheAdapter() async {
        let fixture = TrackedConverterFixture()
        let engine = StubEngine()
        fixture.boundAXEngine = engine
        fixture.mechanisms = [.accessibility]
        fixture.succeed(engine)
        let result = await fixture.converter.trigger()
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        weak var session = fixture.sessions.first
        weak var adapter = fixture.adapters.first
        fixture.sessions.removeAll()
        fixture.adapters.removeAll()
        XCTAssertNil(session)
        XCTAssertNil(adapter)
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(engine.requests.first?.isValid(), false)
        XCTAssertEqual(engine.requests.first?.beginMutation(), false)
        XCTAssertEqual(engine.requests.first?.canCleanup(), false)
        XCTAssertFalse(fixture.owner.isOccupied)
    }
}
