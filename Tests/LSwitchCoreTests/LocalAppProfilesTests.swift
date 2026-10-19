import Foundation
@testable import LSwitchCore
import XCTest

final class LocalAppProfilesTests: XCTestCase {
    @MainActor
    func testPersistenceExactIDResetAndInvalidNames() throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let store = fixture.store
        XCTAssertTrue(store.set(.keyboardClipboard, for: " com.example.Editor "))
        XCTAssertEqual(store.mode(for: "com.example.Editor"), .keyboardClipboard)
        XCTAssertEqual(store.mode(for: "com.example.Editor.helper"), .builtIn)
        XCTAssertEqual(store.mode(for: "com.example.editor"), .builtIn)
        XCTAssertEqual(LocalAppProfiles(defaults: fixture.defaults).mode(for: "com.example.Editor"), .keyboardClipboard)
        let revision = store.revision
        XCTAssertTrue(store.set(.keyboardClipboard, for: "com.example.Editor"))
        XCTAssertEqual(store.revision, revision)
        for identifier in ["", "*", "com.*", "com..app", ".app", "com.app/other", "com.app x"] {
            XCTAssertFalse(store.set(.disabled, for: identifier))
        }
        XCTAssertTrue(store.set(.builtIn, for: "com.example.Editor"))
        XCTAssertTrue(LocalAppProfiles(defaults: fixture.defaults).profiles.isEmpty)
    }

    @MainActor
    func testCorruptedUnknownAndFutureRecordsFailToBuiltin() throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let documents = ["bad", #"{"version":2,"profiles":{"com.app":"disabled"}}"#,
                         #"{"version":1,"profiles":{"com.app":"unknown","*":"accessibility"}}"#]
        for document in documents {
            fixture.defaults.set(Data(document.utf8), forKey: "settings.localAppProfiles.v1")
            XCTAssertTrue(LocalAppProfiles(defaults: fixture.defaults).profiles.isEmpty)
        }
    }

    @MainActor
    func testAXOnlyDoesNotFallbackAndDisabledDoesNotCaptureOrHold() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let converter = ConverterFixture()
        converter.localProfiles = fixture.store
        fixture.store.set(.accessibility, for: "com.example.TextEdit")
        _ = await converter.converter.trigger()
        XCTAssertEqual(converter.axEngine.requests.count, 1)
        XCTAssertTrue(converter.clipboardEngine.requests.isEmpty)
        fixture.store.set(.disabled, for: "com.example.TextEdit")
        let prior = converter.actions
        let outcome = await converter.converter.trigger()
        XCTAssertEqual(outcome, .blockedByRules)
        XCTAssertEqual(converter.actions, prior)
        XCTAssertEqual(converter.axEngine.requests.count, 1)
    }

    @MainActor
    func testKeyboardOverrideAndResetDiscardCachedRouteAndUndo() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let converter = ConverterFixture()
        converter.localProfiles = fixture.store
        converter.clipboardEngine.result = .success(.init(original: "ghbdtn", converted: "привет"))
        _ = await converter.converter.trigger()
        XCTAssertEqual(converter.converter.modeCache["com.example.TextEdit"], .clipboard)
        XCTAssertNotNil(converter.undoStore.pendingUndo())
        fixture.store.set(.accessibility, for: "com.example.TextEdit")
        converter.axEngine.result = .unavailable
        _ = await converter.converter.trigger()
        XCTAssertEqual(converter.clipboardEngine.requests.count, 1)
        XCTAssertNil(converter.undoStore.pendingUndo())
        XCTAssertTrue(converter.converter.modeCache.isEmpty)
        fixture.store.set(.keyboardClipboard, for: "com.example.TextEdit")
        let count = converter.axEngine.requests.count
        _ = await converter.converter.trigger()
        XCTAssertEqual(converter.axEngine.requests.count, count)
        fixture.store.set(.builtIn, for: "com.example.TextEdit")
        _ = await converter.converter.trigger()
        XCTAssertEqual(converter.axEngine.requests.count, count + 1)
    }

    @MainActor
    func testProfileRevisionRejectsABAChangeInsideOperation() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        let converter = ConverterFixture()
        converter.localProfiles = fixture.store
        converter.axEngine.handler = { request in
            XCTAssertTrue(request.isValid())
            fixture.store.set(.disabled, for: "com.example.TextEdit")
            fixture.store.set(.builtIn, for: "com.example.TextEdit")
            XCTAssertFalse(request.isValid())
            return .success(.init(original: "ghbdtn", converted: "привет"))
        }
        _ = await converter.converter.trigger()
        XCTAssertTrue(converter.switchedTo.isEmpty)
        XCTAssertNil(converter.undoStore.pendingUndo())
    }

    @MainActor
    func testLocalProfilesCannotBypassKnownUnsafeAXOrTerminalRules() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        for identifier in ["com.openai.codex", "com.google.Chrome", "com.apple.Safari", "com.microsoft.VSCode",
                           "com.apple.Terminal", "com.googlecode.iterm2"] {
            let converter = ConverterFixture()
            converter.bundleID = identifier
            converter.localProfiles = fixture.store
            fixture.store.set(.accessibility, for: identifier)
            _ = await converter.converter.trigger()
            XCTAssertTrue(converter.axEngine.requests.isEmpty)
            XCTAssertTrue(converter.clipboardEngine.requests.isEmpty)
        }
    }

    @MainActor
    func testTrackedRoutingHonorsExplicitModeAndSessionAdmission() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.name) }
        fixture.store.set(.accessibility, for: "com.example.TextEdit")
        let first = TrackedConverterFixture()
        first.localProfiles = fixture.store
        first.succeed(first.clipboard)
        _ = await first.converter.trigger()
        XCTAssertEqual(first.accessibility.requests.count, 1)
        XCTAssertTrue(first.clipboard.requests.isEmpty)
        fixture.store.set(.keyboardClipboard, for: "com.example.TextEdit")
        let second = TrackedConverterFixture()
        second.localProfiles = fixture.store
        second.mechanisms = [.accessibility]
        _ = await second.converter.trigger()
        XCTAssertTrue(second.accessibility.requests.isEmpty)
        XCTAssertTrue(second.clipboard.requests.isEmpty)
        let third = TrackedConverterFixture()
        third.localProfiles = fixture.store
        third.succeed(third.clipboard)
        let outcome = await third.converter.trigger()
        XCTAssertEqual(outcome, .converted(original: "ghbdtn", converted: "привет"))
        XCTAssertTrue(third.accessibility.requests.isEmpty)
        XCTAssertEqual(third.clipboard.requests.count, 1)
    }

    private struct StoreFixture {
        let store: LocalAppProfiles
        let defaults: UserDefaults
        let name: String
    }

    @MainActor
    private func makeStore() throws -> StoreFixture {
        let name = "LSwitch.LocalProfilesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return StoreFixture(store: LocalAppProfiles(defaults: defaults), defaults: defaults, name: name)
    }
}
