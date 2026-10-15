import Foundation
@testable import LSwitchCore
import XCTest

final class ClipboardCaptureSupportTests: XCTestCase {
    @MainActor
    func testMissingCapabilityDoesNotLaunchOrEnterPendingLifecycle() async {
        let capability = ClipboardHelperCapability(isExecutable: { _ in XCTFail("Нет регистрации"); return false })
        var launches = 0
        let worker = PasteboardCaptureWorker.configured(capability: capability) { _, _, _, _ in
            launches += 1
            return {}
        }
        var phases: [ConversionDiagnostics.Phase] = []
        let diagnostics = ConversionDiagnostics(
            bundleID: "external.host", triggerTimestamp: 10, attempt: 1, automatic: false,
            now: { 20 }, emit: { phases.append($0.phase) }
        )
        let first = await worker.capture(named: "private-fixture", diagnostics: diagnostics)
        let second = await worker.capture(named: "private-fixture", diagnostics: diagnostics)
        XCTAssertEqual(first, .unavailable)
        XCTAssertEqual(second, .unavailable)
        XCTAssertEqual(launches, 0)
        XCTAssertEqual(phases, [.requested])
        XCTAssertNil(capability.executableURL)
    }

    @MainActor
    func testWorkerCreatedBeforeRegistrationUsesOnlyExplicitExecutable() async {
        let capability = ClipboardHelperCapability(isExecutable: { _ in true })
        let executable = URL(fileURLWithPath: "/private/tmp/explicit-host-helper")
        var launched: [URL] = []
        let snapshot = PasteboardSnapshot(items: [.init(dataByType: ["fixture": Data([1, 2, 3])])])
        let worker = PasteboardCaptureWorker.configured(capability: capability) { url, name, started, complete in
            launched.append(url)
            XCTAssertEqual(name, "private-fixture")
            started()
            complete(.init(snapshot: snapshot, changeCountBefore: 4, changeCountAfter: 4))
            return {}
        }
        let unavailable = await worker.capture(named: "private-fixture")
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertTrue(launched.isEmpty)
        XCTAssertTrue(capability.register(executableURL: executable))
        let captured = await worker.capture(named: "private-fixture")
        XCTAssertEqual(captured, .captured(snapshot, changeCount: 4))
        XCTAssertEqual(launched, [executable.standardizedFileURL])
    }

    @MainActor
    func testRegistrationIsImmutableAndIdempotentAfterStandardization() {
        var validations = 0
        let capability = ClipboardHelperCapability(isExecutable: { _ in validations += 1; return true })
        let original = URL(fileURLWithPath: "/private/tmp/fixture-helper")
        let equivalent = URL(fileURLWithPath: "/private/tmp/nested/../fixture-helper")
        XCTAssertTrue(capability.register(executableURL: original))
        XCTAssertTrue(capability.register(executableURL: equivalent))
        XCTAssertFalse(capability.register(executableURL: URL(fileURLWithPath: "/private/tmp/other-helper")))
        XCTAssertEqual(capability.executableURL, original.standardizedFileURL)
        XCTAssertEqual(validations, 1)
    }

    @MainActor
    func testNonlocalOrDecoratedURLsDoNotDeclareCapability() throws {
        let capability = ClipboardHelperCapability(isExecutable: { _ in XCTFail("Недопустимый URL"); return true })
        for value in [
            "https://example.test/helper", "file://remote.test/tmp/helper",
            "file:///private/tmp/helper?query", "file:///private/tmp/helper#fragment"
        ] {
            XCTAssertFalse(capability.register(executableURL: try XCTUnwrap(URL(string: value))))
            XCTAssertNil(capability.executableURL)
        }
    }

    @MainActor
    func testRealValidationRequiresExistingExecutableFileRatherThanDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture-helper")
        let capability = ClipboardHelperCapability()
        XCTAssertFalse(capability.register(executableURL: directory))
        XCTAssertFalse(capability.register(executableURL: executable))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        XCTAssertFalse(capability.register(executableURL: executable))
        XCTAssertNil(capability.executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertTrue(capability.register(executableURL: executable))
        XCTAssertEqual(capability.executableURL, executable.standardizedFileURL)
    }

    @MainActor
    func testUnregisteredHostConversionFailsWithoutLaunchMutationOrRetainedHold() async {
        let capability = ClipboardHelperCapability(isExecutable: { _ in true })
        var launches = 0
        let worker = PasteboardCaptureWorker.configured(capability: capability) { _, _, _, _ in
            launches += 1
            return {}
        }
        let editor = ClipboardEditor(text: "ghbdtn ")
        editor.captureOverride = { await worker.capture(named: "private-fixture") }
        let fixture = ConverterFixture()
        fixture.axEngine.handler = { request in await editor.converter().perform(request) }
        let result = await fixture.converter.trigger(expectedWord: "ghbdtn", trailingText: " ", allowUndo: false)
        XCTAssertEqual(result, .blockedBySafety)
        XCTAssertEqual(launches, 0)
        XCTAssertEqual(editor.writes, 0)
        XCTAssertEqual(editor.restores, 0)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertTrue(editor.commands.isEmpty)
        XCTAssertEqual(fixture.actions, ["hold", "release"])
        XCTAssertFalse(fixture.holdActive)
    }
}
