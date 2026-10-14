@testable import LSwitchCore
import XCTest

/// Мок-движок конвертации: возвращает заданный результат, считает вызовы.
final class StubEngine: ConversionEngine, @unchecked Sendable {
    var result: (original: String, converted: String)?
    var calls = 0

    func perform() async -> (original: String, converted: String)? {
        calls += 1
        return result
    }
}

final class ConverterTests: XCTestCase {

    private var axEngine: StubEngine!
    private var clipboardEngine: StubEngine!
    private var currentLayout: Layout?
    private var switchedTo: [Layout]!
    private var bundleID: String?
    private var undoStore: UndoStore!
    private var appRules: AppRules!
    private var converter: Converter!

    override func setUp() {
        let ax = StubEngine()
        let clipboard = StubEngine()
        axEngine = ax
        clipboardEngine = clipboard
        currentLayout = .english
        switchedTo = []
        bundleID = "com.example.TextEdit"
        undoStore = UndoStore()
        appRules = AppRules(defaults: Self.freshDefaults())
        converter = Converter(
            currentLayout: { [weak self] in self?.currentLayout },
            switchLayout: { [weak self] in self?.switchedTo.append($0) },
            appRules: appRules,
            undoStore: undoStore,
            frontmostBundleID: { [weak self] in self?.bundleID },
            makeAXEngine: { ax },
            makeClipboardEngine: { clipboard }
        )
    }

    private static func freshDefaults() -> UserDefaults {
        let suite = "lswitch.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Не удалось создать тестовый UserDefaults")
        }
        return defaults
    }

    func testAXSuccessCachesModeAndSwitchesLayout() async {
        axEngine.result = ("ghbdtn", "привет")
        let outcome = await converter.trigger()
        XCTAssertEqual(outcome, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(converter.modeCache["com.example.TextEdit"], .accessibility)
        XCTAssertEqual(clipboardEngine.calls, 0)
        XCTAssertEqual(switchedTo, [.russian])
    }

    func testAXFailureFallsBackToClipboardAndCaches() async {
        axEngine.result = nil
        clipboardEngine.result = ("ghbdtn", "привет")
        let outcome = await converter.trigger()
        XCTAssertEqual(outcome, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertEqual(converter.modeCache["com.example.TextEdit"], .clipboard)

        // Второй вызов идёт сразу в clipboard, AX не дёргается.
        axEngine.calls = 0
        clipboardEngine.result = nil
        _ = await converter.trigger()
        XCTAssertEqual(axEngine.calls, 0)
    }

    func testBothEnginesFail() async {
        let outcome = await converter.trigger()
        XCTAssertEqual(outcome, .failed)
        XCTAssertNil(converter.modeCache["com.example.TextEdit"])
    }

    func testBlockedApp() async {
        bundleID = "com.apple.Terminal"
        axEngine.result = ("a", "ф")
        let outcome = await converter.trigger()
        XCTAssertEqual(outcome, .blockedByRules)
        XCTAssertEqual(axEngine.calls, 0)
    }

    func testUnsupportedLayout() async {
        currentLayout = nil
        let outcome = await converter.trigger()
        XCTAssertEqual(outcome, .unsupportedLayout)
        XCTAssertEqual(axEngine.calls, 0)
    }

    // MARK: - Откат

    func testUndoWithinWindow() async {
        axEngine.result = ("ghbdtn", "привет")
        _ = await converter.trigger()
        XCTAssertEqual(switchedTo, [.russian])

        axEngine.result = ("привет", "ghbdtn")
        let outcome = await converter.trigger()
        XCTAssertEqual(outcome, .undone)
        XCTAssertEqual(switchedTo, [.russian, .english])
    }

    func testOtherKeystrokeInvalidatesUndo() async {
        axEngine.result = ("ghbdtn", "привет")
        _ = await converter.trigger()
        converter.notifyOtherKeystroke()

        axEngine.result = ("yjdf", "нова")
        let outcome = await converter.trigger()
        // Откат сброшен — это новая конвертация, а не undo.
        XCTAssertEqual(outcome, .converted(original: "yjdf", converted: "нова"))
    }

    func testUndoWindowExpiry() {
        var now = Date()
        let store = UndoStore(now: { now })
        store.window = 3
        store.save(UndoRecord(original: "a", converted: "ф", layoutBefore: .english, timestamp: now))
        XCTAssertNotNil(store.pendingUndo())
        now = now.addingTimeInterval(4)
        XCTAssertNil(store.pendingUndo())
        // Просроченная запись удаляется — повторный запрос тоже nil.
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

    func testPresetBlacklist() {
        let rules = makeRules()
        XCTAssertTrue(rules.isBlocked(bundleID: "com.apple.Terminal"))
        XCTAssertTrue(rules.isBlocked(bundleID: "com.googlecode.iterm2"))
        XCTAssertFalse(rules.isBlocked(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(rules.isBlocked(bundleID: nil))
    }

    func testUserBlacklistAddRemove() {
        let rules = makeRules()
        rules.addToBlacklist("com.example.MyApp")
        rules.addToBlacklist("com.example.MyApp") // дубликат игнорируется
        rules.addToBlacklist("  ")
        XCTAssertEqual(rules.userBlacklist, ["com.example.MyApp"])
        XCTAssertTrue(rules.isBlocked(bundleID: "com.example.MyApp"))
        rules.removeFromBlacklist("com.example.MyApp")
        XCTAssertFalse(rules.isBlocked(bundleID: "com.example.MyApp"))
    }

    func testUserBlacklistPersistsAcrossInstances() {
        let suite = "lswitch.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Не удалось создать тестовый UserDefaults")
        }
        AppRules(defaults: defaults).addToBlacklist("com.example.App")
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
