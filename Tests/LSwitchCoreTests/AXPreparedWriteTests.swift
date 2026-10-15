import ApplicationServices
@testable import LSwitchCore
import XCTest

final class AXPreparedWriteTests: XCTestCase {
    @MainActor
    func testPreparationIsReadOnlyAndHookPrecedesReceiverWithRawErrorIntact() throws {
        let ledger = ConversionSafetyLedger(generation: 1)
        var calls = 0
        let prepared = AXPreparedWrite { token in
            calls += 1
            XCTAssertEqual(ledger.submissionCount, 1)
            XCTAssertTrue(ledger.hasEditorMutation)
            XCTAssertEqual(token?.operation, ledger.operation)
            return .cannotComplete
        }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(ledger.submissionCount, 0)
        let reply = try XCTUnwrap(prepared.submit {
            XCTAssertEqual(calls, 0)
            return ledger.willSubmit(.selection, operation: ledger.operation)
        })
        XCTAssertEqual(reply.status, .cannotComplete)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(prepared.submit { XCTFail("Нельзя повторять подготовленную запись"); return nil })
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testDeniedBeforeSendNeverCallsReceiverAndCannotBeReused() {
        var calls = 0
        let prepared = AXPreparedWrite { _ in calls += 1; return .success }
        XCTAssertNil(prepared.submit { nil })
        XCTAssertNil(prepared.submitUntracked())
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testBindingForDifferentOperationOrElementCannotPrepareWrites() async {
        for wrongElement in [false, true] {
            let access = AXSafetyTestAccess("ghbdtn ")
            let ledger = ConversionSafetyLedger(generation: 2)
            let other = ConversionSafetyLedger(generation: 2)
            let contract = AXReceiverContract { element, operation in
                AXBoundReceiverContract(
                    element: wrongElement ? access.model.otherElement : element,
                    operation: wrongElement ? operation : other.operation,
                    isValid: { true }, completion: { _, _ in .receiverCompleted }
                )
            }
            let result = await AXTextConverter(access: access, receiverContract: contract).perform(ConversionRequest(
                safetyLedger: ledger
            ))
            XCTAssertEqual(result, .blocked)
            XCTAssertEqual(access.preparations, 0)
            XCTAssertEqual(ledger.submissionCount, 0)
            XCTAssertTrue(access.model.selectionWrites.isEmpty)
        }
    }
}
