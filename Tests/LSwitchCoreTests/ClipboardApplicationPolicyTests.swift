import Foundation
@testable import LSwitchCore
import XCTest

final class ClipboardApplicationPolicyTests: XCTestCase {
    @MainActor
    func testVSCodeDefaultManualAndAutoRefuseBeforePayloadCaptureAndMutation() async {
        for automatic in [false, true] {
            let editor = ClipboardEditor(text: "ghbdtn ")
            editor.applicationBundleID = "com.microsoft.VSCode"
            let fixture = ConverterFixture()
            fixture.bundleID = editor.applicationBundleID
            fixture.clipboardPreferred = AppProfiles().prefersClipboard(bundleID: "com.microsoft.VSCode")
            let engine = editor.converter()
            fixture.clipboardEngine.handler = { await engine.perform($0) }
            var samples: [ConversionDiagnostics.Sample] = []
            let result = await fixture.converter.trigger(
                expectedWord: "ghbdtn", trailingText: " ", allowUndo: !automatic,
                diagnostics: trace { samples.append($0) }
            )
            XCTAssertEqual(result, .blockedBySafety)
            XCTAssertEqual(samples.last?.reason, .unverifiedEditorModel)
            XCTAssertTrue(fixture.axEngine.requests.isEmpty)
            XCTAssertEqual(fixture.clipboardEngine.requests.count, 1)
            XCTAssertTrue(fixture.switchedTo.isEmpty)
            XCTAssertNil(fixture.undoStore.pendingUndo())
            XCTAssertFalse(fixture.rules.isBlocked(bundleID: "com.microsoft.VSCode"))
            XCTAssertTrue(fixture.rules.userBlockedApps.isEmpty)
            XCTAssertEqual(fixture.actions, ["hold", "release"])
            XCTAssertEqual(editor.contextCaptures, 0)
            assertNoPayloadOrMutation(editor)
        }
    }

    @MainActor
    func testOtherApplicationProfilesKeepTheirConversionPath() async {
        let bundles = [
            "com.apple.TextEdit", "com.apple.Safari", "com.google.Chrome", "md.obsidian",
            "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.VSCodeInsiders"
        ]
        for bundle in bundles {
            let editor = ClipboardEditor(text: "ghbdtn ")
            editor.applicationBundleID = bundle
            XCTAssertNil(AppProfiles.clipboardRejection(bundleID: bundle))
            let result = await editor.converter().perform(ConversionRequest(
                expectedWord: "ghbdtn", trailingText: " ", sourceLayout: .english, useSelection: false
            ))
            XCTAssertEqual(result, .success(.init(original: "ghbdtn", converted: "привет", trailingText: " ")))
            XCTAssertEqual(editor.contextCaptures, 1)
            XCTAssertGreaterThan(editor.stateReads, 0)
            XCTAssertEqual(editor.captures, 1)
            XCTAssertEqual(editor.text, "привет ")
            XCTAssertEqual(editor.clipboard, "clipboard before")
        }
    }

    @MainActor
    func testBlockedContextCannotExposeDataEvenIfCalledDirectly() throws {
        let policy = ClipboardApplicationPolicy()
        let context = try XCTUnwrap(policy.capture(bundleID: "com.microsoft.VSCode") {
            XCTFail("Нельзя создавать AX-контекст запрещённого профиля")
            return nil
        })
        XCTAssertFalse(context.isValid())
        XCTAssertEqual(context.safetyFailure?(), .unverifiedEditorModel)
        XCTAssertNil(context.selectedText())
        XCTAssertNil(context.readState())
        XCTAssertNil(context.documentIdentity())
        XCTAssertFalse(context.setSelection(NSRange(location: 0, length: 1)))
    }

    #if DEBUG
    @MainActor
    func testAcceptanceOverrideRequiresKeyboardCopyAndExactTargetTogether() async {
        for keyboardOnly in [false, true] {
            for forceCopy in [false, true] {
                for target in [nil, "com.google.Chrome", "com.microsoft.VSCode"] {
                    let editor = ClipboardEditor(text: "ghbdtn ")
                    editor.applicationBundleID = "com.microsoft.VSCode"
                    editor.applicationPolicy = ClipboardApplicationPolicy(
                        keyboardOnly: keyboardOnly, forceCopyForAcceptance: forceCopy,
                        testApplicationBundleID: target
                    )
                    var configuration = ClipboardConverter.Configuration()
                    configuration.forceCopyForAcceptance = forceCopy
                    let result = await editor.converter(configuration: configuration).perform(ConversionRequest(
                        expectedWord: "ghbdtn", trailingText: " ", sourceLayout: .english
                    ))
                    let allowed = keyboardOnly && forceCopy && target == "com.microsoft.VSCode"
                    if allowed {
                        XCTAssertEqual(result, .success(.init(original: "ghbdtn", converted: "привет",
                                                             trailingText: " ")))
                        XCTAssertEqual(editor.commands, [.selectCharacters(7), .copy, .paste])
                        XCTAssertEqual(editor.captures, 1)
                    } else {
                        XCTAssertEqual(result, .blocked)
                        XCTAssertEqual(editor.contextCaptures, 0)
                        assertNoPayloadOrMutation(editor)
                    }
                }
            }
        }
    }

    @MainActor
    func testAcceptanceOverrideDoesNotBypassProtectedTarget() async {
        let editor = ClipboardEditor(text: "ghbdtn ")
        editor.applicationBundleID = "com.microsoft.VSCode"
        editor.applicationPolicy = ClipboardApplicationPolicy(
            keyboardOnly: true, forceCopyForAcceptance: true, testApplicationBundleID: "com.microsoft.VSCode"
        )
        editor.safetyFailure = { .protectedField }
        var samples: [ConversionDiagnostics.Sample] = []
        let result = await editor.converter().perform(ConversionRequest(diagnostics: trace { samples.append($0) }))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(samples.last?.reason, .protectedField)
        XCTAssertEqual(editor.contextCaptures, 1)
        assertNoPayloadOrMutation(editor)
    }
    #endif

    @MainActor
    private func assertNoPayloadOrMutation(_ editor: ClipboardEditor) {
        XCTAssertEqual(editor.preparations, 0)
        XCTAssertEqual(editor.stateReads, 0)
        XCTAssertEqual(editor.captures, 0)
        XCTAssertEqual(editor.writes, 0)
        XCTAssertEqual(editor.restores, 0)
        XCTAssertEqual(editor.count, 0)
        XCTAssertEqual(editor.text, "ghbdtn ")
        XCTAssertNil(editor.selection)
        XCTAssertEqual(editor.clipboard, "clipboard before")
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertTrue(editor.commands.isEmpty)
    }

    @MainActor
    private func trace(_ emit: @escaping (ConversionDiagnostics.Sample) -> Void) -> ConversionDiagnostics {
        ConversionDiagnostics(
            bundleID: "com.microsoft.VSCode", triggerTimestamp: nil, attempt: 1, automatic: false,
            now: { 20 }, emit: emit
        )
    }
}
