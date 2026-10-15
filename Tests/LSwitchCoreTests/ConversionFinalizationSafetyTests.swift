import Foundation
@testable import LSwitchCore
import XCTest

final class ConversionFinalizationSafetyTests: XCTestCase {
    @MainActor
    func testUnicodeFinalValidityCannotResurrectClosedLedgerOrSupersededCleanup() async {
        for closeLedger in [false, true] {
            let editor = UnicodeSafetyEditor()
            let callback = FinalValidityCallback(closeLedger: closeLedger)
            let result = await editor.converter().perform(callback.request)
            XCTAssertTrue(callback.triggered, "Callback должен сработать после записи recoveredObserved")
            XCTAssertEqual(result, .failed, "Позднее решение запрещает success и receipt")
            XCTAssertTrue(editor.text.utf16.elementsEqual("привет ".utf16))
            XCTAssertEqual(editor.downCount, 1)
            XCTAssertEqual(editor.upCount, 1)
            assertDisposition(callback)
        }
    }

    @MainActor
    func testClipboardFinalValidityCannotResurrectReceiptForEitherSelectionTransport() async {
        for method in [ClipboardEnvironment.SelectionMethod.accessibility, .keyboard] {
            for closeLedger in [false, true] {
                let editor = ClipboardSafetyEditor()
                editor.selectionMethod = method
                let callback = FinalValidityCallback(closeLedger: closeLedger)
                let result = await editor.converter().perform(callback.request)
                XCTAssertTrue(callback.triggered, "Callback должен сработать после записи recoveredObserved")
                XCTAssertEqual(result, .failed, "Позднее решение запрещает success и receipt")
                XCTAssertTrue(editor.text.utf16.elementsEqual("привет ".utf16))
                XCTAssertEqual(editor.commands.filter { $0 == .paste }.count, 1)
                XCTAssertEqual(editor.clipboard, "original clipboard")
                XCTAssertEqual(editor.restores, 1)
                assertDisposition(callback)
            }
        }
    }

    @MainActor
    private func assertDisposition(_ callback: FinalValidityCallback) {
        if callback.closeLedger {
            XCTAssertEqual(callback.ledger.decision?.input, .recoveryRequired)
            XCTAssertEqual(callback.ledger.decision?.permitsConfirmedResult, false)
        } else {
            XCTAssertNil(callback.ledger.decision)
            XCTAssertEqual(callback.ledger.recordedCleanup, .recoveryUnconfirmed)
        }
    }
}

/// Инвалидация происходит в последнем внешнем guard, а не внутри предшествующего snapshot/cleanup.
@MainActor
private final class FinalValidityCallback {
    let ledger = ConversionSafetyLedger(generation: 1)
    let closeLedger: Bool
    private(set) var triggered = false

    init(closeLedger: Bool) { self.closeLedger = closeLedger }

    var request: ConversionRequest {
        .init(expectedWord: "ghbdtn", trailingText: " ", sourceLayout: .english, useSelection: false,
              safetyLedger: ledger, canCleanup: { true }, isValid: { self.validate() })
    }

    private func validate() -> Bool {
        guard !triggered, ledger.recordedCleanup == .recoveredObserved else { return true }
        triggered = true
        if closeLedger {
            XCTAssertNotNil(ledger.finishUsingRecordedCleanup(
                operation: ledger.operation, text: .unknown, ordinaryRouteValid: false
            ))
        } else {
            XCTAssertNotNil(ledger.beginCleanupObservation(operation: ledger.operation))
        }
        return true
    }
}
