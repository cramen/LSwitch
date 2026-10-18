import Foundation
@testable import LSwitchCore
import XCTest

final class ConverterSessionEngineTests: XCTestCase {
    @MainActor
    func testProfileWithoutBoundEngineRefusesBeforeActivationAndNeverUsesGeneralFactory() async throws {
        let fixture = TrackedConverterFixture()
        fixture.profile = try ConversionSafetyProfileFixture().binding
        fixture.mechanisms = [.accessibility]
        var preparedAdapter: TrackedConversionAdapter?
        fixture.configureAdapter = { preparedAdapter = $0 }
        fixture.succeed(fixture.accessibility)
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .blockedBySafety)
        XCTAssertEqual(preparedAdapter?.activations, 0)
        XCTAssertTrue(fixture.sessions.isEmpty)
        XCTAssertTrue(fixture.accessibility.requests.isEmpty)
        XCTAssertTrue(fixture.clipboard.requests.isEmpty)
        XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertFalse(fixture.owner.hasPendingRecovery)
        XCTAssertFalse(fixture.owner.isOccupied)
        XCTAssertNil(fixture.undoStore.pendingUndo())
    }

    @MainActor
    func testBoundEngineIsUsedInsteadOfGeneralAXFactoryForAnUnprofiledSession() async {
        let fixture = TrackedConverterFixture()
        let bound = StubEngine()
        fixture.boundAXEngine = bound
        fixture.mechanisms = [.accessibility]
        fixture.succeed(bound)
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(bound.requests.count, 1)
        XCTAssertTrue(bound.requests.first?.safetyLedger === fixture.sessions.first?.ledger)
        XCTAssertTrue(fixture.accessibility.requests.isEmpty)
        XCTAssertEqual(fixture.adapters.first?.delivered, 2)
    }

    @MainActor
    func testRequestFromAnotherOperationCannotReachTheSessionEngine() async throws {
        let fixture = TrackedConverterFixture()
        let bound = StubEngine()
        fixture.boundAXEngine = bound
        fixture.mechanisms = [.accessibility]
        let admission = try XCTUnwrap(fixture.owner.reserve())
        let context = ConversionRecoveryContext(
            bundleID: "com.example.TextEdit", sourceLayout: .english, generation: 0, startedAt: 0,
            admission: admission, isCurrent: { true }, canCleanup: { true }
        )
        let session = try XCTUnwrap(fixture.makeSession(context))
        let foreign = ConversionSafetyLedger(generation: session.ledger.operation.generation)
        var checks = 0
        for ledger in [nil, foreign] {
            let request = ConversionRequest(safetyLedger: ledger, isValid: { checks += 1; return true })
            let routed = await fixture.converter.performTracked(request, bundleID: context.bundleID, session: session)
            XCTAssertEqual(routed.result, .blocked)
            XCTAssertEqual(routed.mechanism, .none)
        }
        XCTAssertEqual(checks, 0)
        XCTAssertTrue(bound.requests.isEmpty)
        XCTAssertTrue(fixture.accessibility.requests.isEmpty)
        let matching = ConversionRequest(safetyLedger: session.ledger)
        _ = await fixture.converter.performTracked(matching, bundleID: context.bundleID, session: session)
        XCTAssertEqual(bound.requests.count, 1)
        XCTAssertTrue(bound.requests.first?.safetyLedger === session.ledger)
    }

    @MainActor
    func testActualProfileConversionAndUndoUseFreshSessionBoundEngines() async throws {
        let editor = try AXProfileFixture()
        let fixture = TrackedConverterFixture()
        fixture.mechanisms = [.accessibility]
        var preparedProfiles: [AXObservationProfile] = []
        fixture.beforeFactory = {
            guard let profile = editor.profile() else { XCTFail("Нужен свежий профиль"); return }
            preparedProfiles.append(profile)
            fixture.profile = profile.binding
            fixture.boundAXEngine = AXTextConverter(access: editor.access, observationProfile: profile)
        }
        let converted = await fixture.converter.trigger(expectedWord: "ghbdtn", trailingText: " ", allowUndo: false)
        XCTAssertEqual(converted, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(editor.access.model.value, "привет ")
        editor.activeSource = .init(identifier: "com.apple.keylayout.Russian", isKeyboardLayout: true)
        let undone = await fixture.converter.trigger()
        XCTAssertEqual(undone, .undone)
        XCTAssertEqual(editor.access.model.value, "ghbdtn ")
        XCTAssertEqual(editor.access.model.textWrites, 2)
        XCTAssertEqual(preparedProfiles.count, 2)
        XCTAssertNotEqual(preparedProfiles.first?.binding, preparedProfiles.last?.binding)
        XCTAssertEqual(fixture.sessions.count, 2)
        XCTAssertFalse(fixture.sessions.first === fixture.sessions.last)
        XCTAssertFalse(fixture.ledgers.first === fixture.ledgers.last)
        XCTAssertTrue(fixture.ledgers.allSatisfy { $0.decision?.verificationBasis == .observedUnderProfile })
        XCTAssertTrue(fixture.accessibility.requests.isEmpty)
        XCTAssertTrue(fixture.clipboard.requests.isEmpty)
        XCTAssertEqual(fixture.adapters.map(\.delivered), [2, 2])
    }

    @MainActor
    func testReusingAnAlreadyBoundProfileForAnotherOperationCannotWriteOrUseGeneralEngine() async throws {
        let editor = try AXProfileFixture()
        let profile = try XCTUnwrap(editor.profile())
        let engine = AXTextConverter(access: editor.access, observationProfile: profile)
        let fixture = TrackedConverterFixture()
        fixture.mechanisms = [.accessibility]
        fixture.profile = profile.binding
        fixture.boundAXEngine = engine
        let first = await fixture.converter.trigger(expectedWord: "ghbdtn", trailingText: " ", allowUndo: false)
        XCTAssertEqual(first, .converted(original: "ghbdtn", converted: "привет"))
        let reads = editor.snapshotReads
        let selectionWrites = editor.access.model.selectionWrites.count
        let second = await fixture.converter.trigger()
        XCTAssertEqual(second, .recoveryRequired)
        XCTAssertEqual(editor.access.model.value, "привет ")
        XCTAssertEqual(editor.access.model.textWrites, 1)
        XCTAssertEqual(editor.access.model.selectionWrites.count, selectionWrites)
        XCTAssertEqual(editor.snapshotReads, reads)
        XCTAssertEqual(fixture.ledgers.count, 2)
        XCTAssertTrue(try XCTUnwrap(fixture.ledgers.last).hasProfileFault)
        XCTAssertEqual(fixture.adapters.map(\.delivered), [2, 0])
        XCTAssertTrue(fixture.accessibility.requests.isEmpty)
        XCTAssertTrue(fixture.clipboard.requests.isEmpty)
        XCTAssertNil(fixture.undoStore.pendingUndo())
    }
}
