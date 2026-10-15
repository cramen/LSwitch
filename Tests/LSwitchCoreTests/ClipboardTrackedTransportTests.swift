import Foundation
@testable import LSwitchCore
import XCTest

final class ClipboardTrackedTransportTests: XCTestCase {
    @MainActor
    func testUnavailableAfterActualMenuSubmissionCannotFallBackToKeyboard() async {
        let ledger = ConversionSafetyLedger(generation: 1)
        var keyboardCalls = 0
        var transport = transport()
        transport.invokeMenuTracked = { command, _, _, hooks in
            guard let token = hooks.beforeSend(command.submissionKind) else { return .failed }
            hooks.didReturn(.init(submission: token, transport: .menu, status: .cannotComplete))
            return .unavailable
        }
        transport.sendKeyboardTracked = { _, _, _, _, _ in keyboardCalls += 1; return true }
        let result = await transport.send(.copy, isValid: { true }, hooks: hooks(ledger))
        XCTAssertFalse(result)
        XCTAssertEqual(keyboardCalls, 0)
        XCTAssertEqual(ledger.submissionCount, 1)
    }

    @MainActor
    func testGenuinelyUnavailableMenuMaySelectKeyboardBeforeAnySubmission() async {
        let ledger = ConversionSafetyLedger(generation: 2)
        var keyboardCalls = 0
        var transport = transport()
        transport.invokeMenuTracked = { _, _, _, _ in .unavailable }
        transport.sendKeyboardTracked = { command, _, _, _, hooks in
            keyboardCalls += 1
            guard let token = hooks.beforeSend(command.submissionKind) else { return false }
            hooks.didReturn(.init(submission: token, transport: .keyboard, status: nil))
            return true
        }
        let result = await transport.send(.copy, isValid: { true }, hooks: hooks(ledger))
        XCTAssertTrue(result)
        XCTAssertEqual(keyboardCalls, 1)
        XCTAssertEqual(ledger.submissionCount, 1)
    }

    @MainActor
    func testTrackedKeyboardPasteRechecksTargetAfterSelection() async {
        let ledger = ConversionSafetyLedger(generation: 3)
        var target: pid_t = 100
        var transport = transport()
        transport.forceKeyboard = true
        transport.currentTarget = { .init(processID: target, bundleID: "test") }
        transport.sendKeyboardTracked = { _, _, _, _, _ in XCTFail("Цель изменилась"); return true }
        let result = await transport.commitPaste(
            select: { target = 200; return true }, check: { true }, isValid: { true }, hooks: hooks(ledger)
        )
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(ledger.submissionCount, 0)
    }

    @MainActor
    func testMissingTrackedTransportNeverFallsThroughToLegacySending() async {
        let ledger = ConversionSafetyLedger(generation: 4)
        let result = await transport().send(.paste, isValid: { true }, hooks: hooks(ledger))
        XCTAssertFalse(result)
        XCTAssertEqual(ledger.submissionCount, 0)
    }

    @MainActor
    private func transport() -> ClipboardCommandTransport {
        ClipboardCommandTransport(
            currentTarget: { .init(processID: 100, bundleID: "test") }, prepareMenu: { _, _ in },
            invokeMenu: { _, _, _ in XCTFail("Tracked не использует legacy"); return .failed },
            commitMenu: { _, _, _, _ in XCTFail("Tracked не использует legacy"); return .failed },
            sendKeyboard: { _, _, _, _ in XCTFail("Tracked не использует legacy"); return false }
        )
    }

    @MainActor
    private func hooks(_ ledger: ConversionSafetyLedger) -> ClipboardDispatchHooks {
        .init(beforeSend: { ledger.willSubmit($0, operation: ledger.operation) }, didReturn: {
            ledger.observe(.adapterReturned($0.returnedSuccessfully), for: $0.submission)
        }, submissionCount: { ledger.submissionCount })
    }
}
