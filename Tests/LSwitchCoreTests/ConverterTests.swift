@testable import LSwitchCore
import XCTest

final class ConverterTests: XCTestCase {
    @MainActor
    func testSafariAvoidsUnreliableAXWrites() async {
        XCTAssertTrue(AppProfiles().prefersClipboard(bundleID: "com.apple.Safari"))
    }

    func testManualSelectionUsesTextLanguageAndPreservesMixedConversion() {
        let request = ConversionRequest(sourceLayout: .english)
        XCTAssertEqual(request.converted("руддщ"), "hello")
        XCTAssertEqual(request.targetLayout(for: "руддщ"), .english)
        XCTAssertEqual(request.converted("ghbdtn руддщ"), "привет hello")
        XCTAssertEqual(request.converted("/"), ".")
    }

    @MainActor
    func testAXSuccessCachesModeAndSwitchesLayout() async {
        let fixture = ConverterFixture()
        fixture.succeed(fixture.axEngine)
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(fixture.converter.modeCache["com.example.TextEdit"], .accessibility)
        XCTAssertTrue(fixture.clipboardEngine.requests.isEmpty)
        XCTAssertEqual(fixture.switchedTo, [.russian])
        XCTAssertEqual(fixture.transitions.first?.source, .english)
        XCTAssertEqual(fixture.transitions.first?.target, .russian)
        XCTAssertGreaterThan(fixture.transitions.first?.startedAt ?? 0, 0)
    }

    @MainActor
    func testUnconfirmedLayoutSwitchDoesNotCorrectQueuedInput() async {
        let fixture = ConverterFixture()
        fixture.switchSucceeds = false
        fixture.succeed(fixture.axEngine)
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .partiallyConverted(original: "ghbdtn", converted: "привет", targetLayout: .russian))
        XCTAssertTrue(fixture.transitions.isEmpty)
    }

    @MainActor
    func testAlreadyCorrectLayoutDoesNotCorrectQueuedInput() async {
        let fixture = ConverterFixture()
        fixture.succeed(fixture.axEngine, original: "руддщ", converted: "hello")
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .converted(original: "руддщ", converted: "hello"))
        XCTAssertTrue(fixture.switchedTo.isEmpty)
        XCTAssertTrue(fixture.transitions.isEmpty)
    }

    @MainActor
    func testUnavailableFallsBackAndCachesOnlySuccessfulClipboard() async {
        let fixture = ConverterFixture()
        fixture.succeed(fixture.clipboardEngine)
        _ = await fixture.converter.trigger()
        XCTAssertEqual(fixture.converter.modeCache["com.example.TextEdit"], .clipboard)
        fixture.converter.notifyOtherKeystroke()
        _ = await fixture.converter.trigger()
        XCTAssertEqual(fixture.axEngine.requests.count, 1)
    }

    @MainActor
    func testFailedOrBlockedAXDoesNotTryClipboard() async {
        for result: ConversionResult in [.blocked, .failed] {
            let fixture = ConverterFixture()
            fixture.axEngine.result = result
            fixture.succeed(fixture.clipboardEngine)
            _ = await fixture.converter.trigger()
            XCTAssertTrue(fixture.clipboardEngine.requests.isEmpty)
            XCTAssertTrue(fixture.switchedTo.isEmpty)
        }
    }

    @MainActor
    func testBothUnavailableDoNotPoisonCache() async {
        let fixture = ConverterFixture()
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(fixture.converter.modeCache.isEmpty)
    }

    @MainActor
    func testClipboardProfileStillHonorsSafety() async {
        let fixture = ConverterFixture()
        fixture.clipboardPreferred = true
        fixture.safe = false
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .blockedBySafety)
        XCTAssertTrue(fixture.axEngine.requests.isEmpty)
        XCTAssertTrue(fixture.clipboardEngine.requests.isEmpty)
    }

    @MainActor
    func testBlockedAppAndUnsupportedLayoutNeverCallEngines() async {
        let fixture = ConverterFixture()
        fixture.bundleID = "com.apple.Terminal"
        let blocked = await fixture.converter.trigger()
        XCTAssertEqual(blocked, .blockedByRules)
        fixture.bundleID = "com.example.TextEdit"
        fixture.layout = nil
        let unsupported = await fixture.converter.trigger()
        XCTAssertEqual(unsupported, .unsupportedLayout)
        XCTAssertTrue(fixture.axEngine.requests.isEmpty)
        XCTAssertTrue(fixture.clipboardEngine.requests.isEmpty)
    }

    @MainActor
    func testUndoUsesExactOriginalAndTail() async throws {
        let fixture = ConverterFixture()
        fixture.axEngine.result = .success(ConversionReceipt(original: "/", converted: ".", trailingText: " "))
        _ = await fixture.converter.trigger(expectedWord: "/", trailingText: " ")
        fixture.axEngine.result = .success(ConversionReceipt(original: ".", converted: "/", trailingText: " "))
        let outcome = await fixture.converter.trigger()
        let request = try XCTUnwrap(fixture.axEngine.requests.last)
        XCTAssertEqual(outcome, .undone)
        XCTAssertEqual(request.expectedWord, ".")
        XCTAssertEqual(request.replacement, "/")
        XCTAssertEqual(request.trailingText, " ")
        XCTAssertFalse(request.useSelection)
        XCTAssertEqual(fixture.switchedTo, [.russian, .english])
    }

    @MainActor
    func testDifferentFieldPreventsUndo() async {
        let fixture = ConverterFixture()
        fixture.succeed(fixture.axEngine)
        _ = await fixture.converter.trigger()
        fixture.contextValid = false
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .blockedBySafety)
        XCTAssertEqual(fixture.axEngine.requests.count, 1)
    }

    @MainActor
    func testOtherKeystrokeInvalidatesUndoAndCurrentRequest() async {
        let fixture = ConverterFixture()
        fixture.succeed(fixture.axEngine)
        _ = await fixture.converter.trigger()
        let request = fixture.axEngine.requests[0]
        fixture.converter.notifyOtherKeystroke()
        XCTAssertFalse(request.isValid())
        XCTAssertNil(fixture.undoStore.pendingUndo())
    }

    @MainActor
    func testAutoRequestIncludesDelimiterAndIgnoresSelection() async throws {
        let fixture = ConverterFixture()
        fixture.succeed(fixture.axEngine)
        _ = await fixture.converter.trigger(expectedWord: "ghbdtn", trailingText: ",", allowUndo: false)
        let request = try XCTUnwrap(fixture.axEngine.requests.first)
        XCTAssertEqual(request.expectedSpan, "ghbdtn,")
        XCTAssertFalse(request.useSelection)
        XCTAssertEqual(request.sourceLayout, .english)
    }

    @MainActor
    func testOverlappingRequestIsRejected() async {
        let fixture = ConverterFixture()
        var nested: Converter.Outcome?
        fixture.axEngine.handler = { _ in
            nested = await fixture.converter.trigger()
            return .success(ConversionReceipt(original: "ghbdtn", converted: "привет"))
        }
        _ = await fixture.converter.trigger()
        XCTAssertEqual(nested, .busy)
        XCTAssertEqual(fixture.axEngine.requests.count, 1)
        XCTAssertFalse(fixture.converter.isBusy)
    }

    @MainActor
    func testInvalidationDuringAXDoesNotStartFallback() async {
        let fixture = ConverterFixture()
        fixture.axEngine.handler = { _ in
            fixture.converter.notifyOtherKeystroke()
            return .unavailable
        }
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .blockedBySafety)
        XCTAssertTrue(fixture.clipboardEngine.requests.isEmpty)
        XCTAssertTrue(fixture.switchedTo.isEmpty)
    }

    func testUndoWindowExpiry() {
        var now = Date()
        let store = UndoStore(now: { now })
        store.window = 3
        store.save(UndoRecord(original: "a", converted: "ф", layoutBefore: .english, timestamp: now))
        XCTAssertNotNil(store.pendingUndo())
        now = now.addingTimeInterval(4)
        XCTAssertNil(store.pendingUndo())
    }
}

final class AppRulesTests: XCTestCase {

    private func makeRules() -> AppRules {
        let suite = "lswitch.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Не удалось создать тестовый UserDefaults")
        }
        return AppRules(defaults: defaults)
    }

    func testPresetBlockedApps() {
        let rules = makeRules()
        XCTAssertTrue(rules.isBlocked(bundleID: "com.apple.Terminal"))
        XCTAssertTrue(rules.isBlocked(bundleID: "com.googlecode.iterm2"))
        XCTAssertFalse(rules.isBlocked(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(rules.isBlocked(bundleID: nil))
    }

    func testUserBlockedAppsAddRemove() {
        let rules = makeRules()
        rules.addBlockedApp("com.example.MyApp")
        rules.addBlockedApp("com.example.MyApp") // дубликат игнорируется
        rules.addBlockedApp("  ")
        XCTAssertEqual(rules.userBlockedApps, ["com.example.MyApp"])
        XCTAssertTrue(rules.isBlocked(bundleID: "com.example.MyApp"))
        rules.removeBlockedApp("com.example.MyApp")
        XCTAssertFalse(rules.isBlocked(bundleID: "com.example.MyApp"))
    }

    func testUserBlockedAppsPersistsAcrossInstances() {
        let suite = "lswitch.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Не удалось создать тестовый UserDefaults")
        }
        AppRules(defaults: defaults).addBlockedApp("com.example.App")
        let reloaded = AppRules(defaults: defaults)
        XCTAssertTrue(reloaded.isBlocked(bundleID: "com.example.App"))
    }
}

final class SettingsStoreTests: XCTestCase {

    private func makeStore() -> (SettingsStore, UserDefaults) {
        let suite = "lswitch.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Не удалось создать тестовый UserDefaults")
        }
        return (SettingsStore(defaults: defaults), defaults)
    }

    func testDefaults() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.enabled)
        XCTAssertEqual(store.undoWindowSeconds, 3)
        XCTAssertTrue(store.soundEnabled)
        XCTAssertFalse(store.launchAtLogin)
    }

    func testRoundTrip() {
        let (store, defaults) = makeStore()
        store.enabled = false
        store.undoWindowSeconds = 5
        store.soundEnabled = false

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.enabled)
        XCTAssertEqual(reloaded.undoWindowSeconds, 5)
        XCTAssertFalse(reloaded.soundEnabled)
    }
}
