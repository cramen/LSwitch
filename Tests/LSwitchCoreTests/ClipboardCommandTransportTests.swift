@testable import LSwitchCore
import XCTest

final class ClipboardCommandTransportTests: XCTestCase {
    @MainActor
    func testChromeSnapshotPasteSkipsMenuAndCopy() async {
        let fixture = CommandTransportFixture(bundleID: "com.google.Chrome")
        let transport = fixture.transport()
        transport.prepare(isValid: { fixture.valid })
        let result = await transport.commitPaste(
            select: { fixture.selected = true; return true },
            check: { fixture.selected }, isValid: { fixture.valid }
        )
        XCTAssertEqual(result, .performed)
        XCTAssertEqual(fixture.keyboardCommands, [.paste])
        XCTAssertEqual(fixture.menuCalls, 0)
        XCTAssertEqual(fixture.keyDowns, 1)
    }

    @MainActor
    func testChromeLegacyCopyAndForcedAcceptanceUseSameKeyboardTransport() async {
        for bundleID in ["com.google.Chrome", "com.apple.TextEdit"] {
            let fixture = CommandTransportFixture(bundleID: bundleID)
            let transport = fixture.transport(forceKeyboard: bundleID == "com.apple.TextEdit")
            transport.prepare(isValid: { fixture.valid })
            let copied = await transport.send(.copy, isValid: { fixture.valid })
            XCTAssertTrue(copied)
            XCTAssertEqual(fixture.keyboardCommands, [.copy])
            XCTAssertEqual(fixture.menuCalls, 0)
        }
    }

    @MainActor
    func testOtherApplicationsRetainMenuTransport() async {
        let fixture = CommandTransportFixture(bundleID: "com.apple.Safari")
        let transport = fixture.transport()
        transport.prepare(isValid: { fixture.valid })
        let copied = await transport.send(.copy, isValid: { fixture.valid })
        let pasted = await transport.commitPaste(select: { true }, check: { true }, isValid: { fixture.valid })
        XCTAssertTrue(copied)
        XCTAssertEqual(pasted, .performed)
        XCTAssertEqual(fixture.menuCalls, 3)
        XCTAssertTrue(fixture.keyboardCommands.isEmpty)
    }

    @MainActor
    func testTargetChangeDuringSelectionCancelsBeforeKeyboardCommand() async {
        let fixture = CommandTransportFixture(bundleID: "com.google.Chrome")
        let result = await fixture.transport().commitPaste(
            select: { fixture.processID = 200; return true }, check: { true }, isValid: { true }
        )
        XCTAssertEqual(result, .failed)
        XCTAssertTrue(fixture.keyboardCommands.isEmpty)
        XCTAssertEqual(fixture.menuCalls, 0)
    }

    @MainActor
    func testClipboardOwnershipAndSelectionAreRecheckedImmediatelyBeforeKeyDown() async {
        for invalidateClipboard in [true, false] {
            let fixture = CommandTransportFixture(bundleID: "com.google.Chrome")
            fixture.selected = true
            fixture.beforeKeyDown = {
                if invalidateClipboard { fixture.valid = false } else { fixture.selected = false }
            }
            let result = await fixture.transport().commitPaste(
                select: { true }, check: { fixture.selected }, isValid: { fixture.valid }
            )
            XCTAssertEqual(result, .failed)
            XCTAssertEqual(fixture.keyboardCommands, [.paste])
            XCTAssertEqual(fixture.keyDowns, 0)
            XCTAssertEqual(fixture.menuCalls, 0)
        }
    }

    @MainActor
    func testPasteFailureDoesNotRetryAnotherTransport() async {
        let fixture = CommandTransportFixture(bundleID: "com.google.Chrome")
        fixture.keyboardSucceeded = false
        let result = await fixture.transport().commitPaste(select: { true }, check: { true }, isValid: { true })
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(fixture.keyboardCommands, [.paste])
        XCTAssertEqual(fixture.keyDowns, 1)
        XCTAssertEqual(fixture.menuCalls, 0)
    }

    @MainActor
    func testMenuFailureDoesNotFallBackToKeyboardButUnavailabilityCan() async {
        for outcome in [MenuCommand.Outcome.failed, .unavailable] {
            let fixture = CommandTransportFixture(bundleID: "com.apple.Safari")
            fixture.menuOutcome = outcome
            let result = await fixture.transport().send(.copy, isValid: { true })
            XCTAssertEqual(result, outcome == .unavailable)
            XCTAssertEqual(fixture.keyboardCommands, outcome == .unavailable ? [.copy] : [])
            XCTAssertEqual(fixture.menuCalls, 1)
        }
    }
}

@MainActor
private final class CommandTransportFixture {
    var processID: pid_t = 100
    let bundleID: String
    var valid = true
    var selected = false
    var menuCalls = 0
    var keyboardCommands: [ClipboardCommand] = []
    var keyDowns = 0
    var menuOutcome = MenuCommand.Outcome.performed
    var keyboardSucceeded = true
    var beforeKeyDown: () -> Void = {}

    init(bundleID: String) { self.bundleID = bundleID }

    func transport(forceKeyboard: Bool = false) -> ClipboardCommandTransport {
        ClipboardCommandTransport(
            forceKeyboard: forceKeyboard,
            currentTarget: { .init(processID: self.processID, bundleID: self.bundleID) },
            prepareMenu: { _, _ in self.menuCalls += 1 },
            invokeMenu: { _, _, _ in self.menuCalls += 1; return self.menuOutcome },
            commitMenu: { _, _, _, _ in self.menuCalls += 1; return self.menuOutcome },
            sendKeyboard: { command, targetPID, valid, beforeKeyDown in
                XCTAssertEqual(targetPID, self.processID)
                self.keyboardCommands.append(command)
                self.beforeKeyDown()
                guard valid(), beforeKeyDown() else { return false }
                self.keyDowns += 1
                return self.keyboardSucceeded && valid()
            }
        )
    }
}
