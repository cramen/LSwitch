@testable import LSwitchCore
import XCTest

final class ConverterPartialResultTests: XCTestCase {
    @MainActor
    func testPartialConversionKeepsExactUndoAndDoesNotRetryTextOrSignalSuccess() async throws {
        let fixture = ConverterFixture()
        fixture.switchSucceeds = false
        fixture.axEngine.result = .success(ConversionReceipt(original: "/", converted: ".", trailingText: "\u{00a0}"))
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .partiallyConverted(original: "/", converted: ".", targetLayout: .russian))
        let undo = try XCTUnwrap(fixture.undoStore.pendingUndo())
        XCTAssertEqual(undo.original, "/")
        XCTAssertEqual(undo.converted, ".")
        XCTAssertEqual(undo.trailingText, "\u{00a0}")
        XCTAssertEqual(undo.layoutBefore, .english)
        XCTAssertEqual(undo.bundleID, fixture.bundleID)
        XCTAssertEqual(fixture.axEngine.requests.count, 1)
        XCTAssertTrue(fixture.clipboardEngine.requests.isEmpty)
        XCTAssertEqual(fixture.converter.modeCache["com.example.TextEdit"], .accessibility)
        XCTAssertEqual(fixture.convertedNotifications, 0)
        XCTAssertTrue(fixture.transitions.isEmpty)
        XCTAssertEqual(fixture.actions, ["hold", "layout", "release"])
        XCTAssertFalse(fixture.holdActive)
        XCTAssertFalse(fixture.converter.isBusy)
    }

    @MainActor
    func testNextHotkeyAfterPartialConversionRestoresOriginalWithoutRetryingFailedSwitch() async throws {
        let fixture = ConverterFixture()
        fixture.switchSucceeds = false
        fixture.axEngine.result = .success(ConversionReceipt(original: "/", converted: ".", trailingText: " "))
        _ = await fixture.converter.trigger()
        fixture.axEngine.result = .success(ConversionReceipt(original: ".", converted: "/", trailingText: " "))
        fixture.actions.removeAll()
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .undone)
        let request = try XCTUnwrap(fixture.axEngine.requests.last)
        XCTAssertEqual(request.expectedWord, ".")
        XCTAssertEqual(request.trailingText, " ")
        XCTAssertEqual(request.replacement, "/")
        XCTAssertFalse(request.useSelection)
        XCTAssertEqual(fixture.switchedTo, [.russian])
        XCTAssertEqual(fixture.layout, .english)
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertEqual(fixture.convertedNotifications, 0)
        XCTAssertTrue(fixture.transitions.isEmpty)
        XCTAssertEqual(fixture.actions, ["hold", "release"])
    }

    @MainActor
    func testPartialConversionUndoStillRequiresUnchangedContext() async {
        let fixture = ConverterFixture()
        fixture.switchSucceeds = false
        fixture.succeed(fixture.axEngine)
        _ = await fixture.converter.trigger()
        fixture.contextValid = false
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .blockedBySafety)
        XCTAssertEqual(fixture.axEngine.requests.count, 1)
        XCTAssertEqual(fixture.switchedTo, [.russian])
        XCTAssertEqual(fixture.convertedNotifications, 0)
    }

    @MainActor
    func testNewInputInvalidatesPartialConversionUndo() async throws {
        let fixture = ConverterFixture()
        fixture.switchSucceeds = false
        fixture.succeed(fixture.axEngine)
        _ = await fixture.converter.trigger()
        fixture.converter.notifyOtherKeystroke()
        XCTAssertNil(fixture.undoStore.pendingUndo())
        fixture.succeed(fixture.axEngine, original: "руддщ", converted: "hello")
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .converted(original: "руддщ", converted: "hello"))
        let request = try XCTUnwrap(fixture.axEngine.requests.last)
        XCTAssertNil(request.replacement)
        XCTAssertTrue(request.useSelection)
    }

    @MainActor
    func testPartialUndoConsumesRecordAndReleasesInputAfterFailedSwitch() async {
        let fixture = ConverterFixture()
        fixture.succeed(fixture.axEngine)
        _ = await fixture.converter.trigger()
        fixture.axEngine.result = .success(ConversionReceipt(original: "привет", converted: "ghbdtn"))
        fixture.switchHandler = { target in
            XCTAssertEqual(target, .english)
            XCTAssertTrue(fixture.holdActive)
            XCTAssertNil(fixture.undoStore.pendingUndo(), "Запись потреблена до повторной записи оригинала")
            return false
        }
        fixture.actions.removeAll()
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .partiallyUndone(targetLayout: .english))
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertEqual(fixture.layout, .russian)
        XCTAssertEqual(fixture.convertedNotifications, 1)
        XCTAssertEqual(fixture.transitions.count, 1)
        XCTAssertEqual(fixture.actions, ["hold", "layout", "release"])
        XCTAssertFalse(fixture.holdActive)
        XCTAssertFalse(fixture.converter.isBusy)
    }

    @MainActor
    func testNextHotkeyAfterPartialUndoStartsNewConversionInsteadOfReusingStaleUndo() async throws {
        let fixture = ConverterFixture()
        fixture.succeed(fixture.axEngine)
        _ = await fixture.converter.trigger()
        fixture.switchSucceeds = false
        fixture.axEngine.result = .success(ConversionReceipt(original: "привет", converted: "ghbdtn"))
        let partial = await fixture.converter.trigger()
        XCTAssertEqual(partial, .partiallyUndone(targetLayout: .english))
        fixture.succeed(fixture.axEngine)
        let repeated = await fixture.converter.trigger()
        XCTAssertEqual(repeated, .converted(original: "ghbdtn", converted: "привет"))
        let request = try XCTUnwrap(fixture.axEngine.requests.last)
        XCTAssertNil(request.replacement)
        XCTAssertNil(request.expectedWord)
        XCTAssertTrue(request.useSelection)
        XCTAssertEqual(fixture.switchedTo, [.russian, .english])
        XCTAssertEqual(fixture.undoStore.pendingUndo()?.original, "ghbdtn")
        XCTAssertEqual(fixture.undoStore.pendingUndo()?.layoutBefore, .russian)
    }

    @MainActor
    func testAcceptedCommandWithoutMatchingReadbackIsPartialConversion() async {
        let fixture = ConverterFixture()
        fixture.appliesRequestedLayout = false
        fixture.succeed(fixture.axEngine)
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .partiallyConverted(original: "ghbdtn", converted: "привет", targetLayout: .russian))
        XCTAssertEqual(fixture.layout, .english)
        XCTAssertTrue(fixture.transitions.isEmpty)
        XCTAssertEqual(fixture.convertedNotifications, 0)
        XCTAssertNotNil(fixture.undoStore.pendingUndo())
        XCTAssertEqual(fixture.actions.last, "release")
    }

    @MainActor
    func testRejectedSwitchDoesNotSignalSuccessEvenIfSourceChangesIndependently() async {
        let fixture = ConverterFixture()
        fixture.succeed(fixture.axEngine)
        fixture.switchHandler = { target in
            fixture.layout = target
            return false
        }
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .partiallyConverted(original: "ghbdtn", converted: "привет", targetLayout: .russian))
        XCTAssertTrue(fixture.transitions.isEmpty)
        XCTAssertEqual(fixture.convertedNotifications, 0)
        XCTAssertNotNil(fixture.undoStore.pendingUndo())
        XCTAssertFalse(fixture.holdActive)
    }

    @MainActor
    func testClipboardTextSuccessWithTISFailureDoesNotRetryAnotherEngine() async {
        let fixture = ConverterFixture()
        fixture.clipboardPreferred = true
        fixture.switchSucceeds = false
        fixture.succeed(fixture.clipboardEngine)
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .partiallyConverted(original: "ghbdtn", converted: "привет", targetLayout: .russian))
        XCTAssertEqual(fixture.clipboardEngine.requests.count, 1)
        XCTAssertTrue(fixture.axEngine.requests.isEmpty)
        XCTAssertNotNil(fixture.undoStore.pendingUndo())
        XCTAssertEqual(fixture.convertedNotifications, 0)
        XCTAssertFalse(fixture.holdActive)
    }

    @MainActor
    func testAcceptedCommandWithoutMatchingReadbackIsPartialUndo() async {
        let fixture = ConverterFixture()
        fixture.succeed(fixture.axEngine)
        _ = await fixture.converter.trigger()
        fixture.appliesRequestedLayout = false
        fixture.axEngine.result = .success(ConversionReceipt(original: "привет", converted: "ghbdtn"))
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .partiallyUndone(targetLayout: .english))
        XCTAssertNil(fixture.undoStore.pendingUndo())
        XCTAssertEqual(fixture.transitions.count, 1)
        XCTAssertEqual(fixture.convertedNotifications, 1)
        XCTAssertFalse(fixture.holdActive)
    }

    @MainActor
    func testUnavailableLayoutReadbackDoesNotConfirmOrCorrectQueuedInput() async {
        let fixture = ConverterFixture()
        fixture.succeed(fixture.axEngine)
        fixture.switchHandler = { _ in
            XCTAssertTrue(fixture.holdActive)
            fixture.layout = nil
            return true
        }
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .partiallyConverted(original: "ghbdtn", converted: "привет", targetLayout: .russian))
        XCTAssertTrue(fixture.transitions.isEmpty)
        XCTAssertEqual(fixture.convertedNotifications, 0)
        XCTAssertNotNil(fixture.undoStore.pendingUndo())
        XCTAssertFalse(fixture.holdActive)
        let retry = await fixture.converter.trigger()
        XCTAssertEqual(retry, .unsupportedLayout)
        XCTAssertEqual(fixture.axEngine.requests.count, 1)
    }

    @MainActor
    func testAlreadyCorrectLayoutIsFullSuccessWithoutCallingFailingAdapter() async {
        let fixture = ConverterFixture()
        fixture.switchSucceeds = false
        fixture.succeed(fixture.axEngine, original: "руддщ", converted: "hello")
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .converted(original: "руддщ", converted: "hello"))
        XCTAssertTrue(fixture.switchedTo.isEmpty)
        XCTAssertTrue(fixture.transitions.isEmpty)
        XCTAssertEqual(fixture.convertedNotifications, 1)
        XCTAssertEqual(fixture.actions, ["hold", "sound", "release"])
    }
}
