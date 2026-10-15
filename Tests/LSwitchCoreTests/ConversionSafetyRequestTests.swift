@testable import LSwitchCore
import XCTest

final class ConversionSafetyRequestTests: XCTestCase {
    @MainActor
    func testTargetWrapperRecordsUnknownInOriginalLedgerAfterTargetChanges() throws {
        let context = RequestSafetyContext()
        let ledger = ConversionSafetyLedger(generation: 1)
        let original = ConversionRequest(useSelection: false, safetyLedger: ledger)
        let wrapped = original.checkingTarget { context.current }
        XCTAssertTrue(wrapped.isValid())
        let throughWrapper = try XCTUnwrap(wrapped.safetyLedger)
        let token = try XCTUnwrap(throughWrapper.willSubmit(.selection, operation: ledger.operation))
        XCTAssertEqual(ledger.submissionCount, 1)
        XCTAssertTrue(ledger.hasEditorMutation)

        context.current = false
        XCTAssertFalse(wrapped.isValid())
        XCTAssertFalse(wrapped.canCleanup())
        XCTAssertTrue(throughWrapper.observe(.unknown, for: token))
        XCTAssertTrue(ledger.hasUnknownSubmissions)
        XCTAssertNil(ledger.willSubmit(.text, operation: ledger.operation))
        let decision = try XCTUnwrap(ledger.finish(
            operation: ledger.operation, text: .unchangedByOperation,
            cleanup: .recoveryUnconfirmed, ordinaryRouteValid: false
        ))
        XCTAssertEqual(decision.input, .recoveryRequired)
        XCTAssertFalse(decision.permitsConfirmedResult)
        XCTAssertEqual(throughWrapper.claimInput(operation: ledger.operation)?.owner, .recovery)
        XCTAssertNil(ledger.claimInput(operation: ledger.operation))
    }

    @MainActor
    func testDocumentWrapperKeepsEarlierUnknownWhenItsCleanupCompletes() throws {
        let context = RequestSafetyContext()
        let ledger = ConversionSafetyLedger(generation: 2)
        let pending = try XCTUnwrap(ledger.willSubmit(.selection, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.unknown, for: pending))
        let original = ConversionRequest(useSelection: false, safetyLedger: ledger)
        let wrapped = original.checkingDocumentContext(context.automatic) { context.automatic }
        let throughWrapper = try XCTUnwrap(wrapped.safetyLedger)
        XCTAssertTrue(wrapped.canCleanup())
        XCTAssertNil(throughWrapper.willSubmit(.text, operation: ledger.operation))
        let cleanup = try XCTUnwrap(throughWrapper.willSubmitCleanup(
            .restoreSelection, operation: ledger.operation
        ))
        XCTAssertTrue(throughWrapper.observe(.receiverCompleted, for: cleanup))
        XCTAssertEqual(ledger.submissionCount, 2)
        XCTAssertTrue(ledger.hasUnknownSubmissions)

        let decision = try XCTUnwrap(ledger.finish(
            operation: ledger.operation, text: .unchangedByOperation,
            cleanup: .recoveredObserved, ordinaryRouteValid: true
        ))
        XCTAssertEqual(decision.cleanup, .recoveredObserved)
        XCTAssertEqual(decision.input, .recoveryRequired)
        XCTAssertFalse(decision.permitsConfirmedResult)
        XCTAssertEqual(throughWrapper.claimInput(operation: ledger.operation)?.owner, .recovery)
        XCTAssertNil(ledger.claimInput(operation: ledger.operation))
        context.document = "fixture:other"
        XCTAssertFalse(wrapped.isValid())
        XCTAssertFalse(wrapped.canCleanup())
    }

    @MainActor
    func testUnicodePrivateScopePreservesSubmissionsAcrossAllRequestWrappers() throws {
        let context = RequestSafetyContext()
        let ledger = ConversionSafetyLedger(generation: 3)
        let earlier = try XCTUnwrap(ledger.willSubmit(.copy, operation: ledger.operation))
        XCTAssertTrue(ledger.observe(.receiverCompleted, for: earlier))
        let original = ConversionRequest(expectedWord: "fixture", useSelection: false, safetyLedger: ledger)
        let guarded = original.checkingTarget { context.current }
            .checkingDocumentContext(context.automatic) { context.automatic }
        let source = try XCTUnwrap(UnicodeInputSource(identifier: "com.apple.keylayout.ABC", isKeyboardLayout: true))
        let boundary = try XCTUnwrap(UnicodeReadBoundary.capture(
            context: context.unicode, request: guarded, source: source, activeSource: { source }
        ))
        XCTAssertTrue(boundary.isValid)
        let throughScope = try XCTUnwrap(boundary.request.safetyLedger)
        let pending = try XCTUnwrap(throughScope.willSubmit(.selection, operation: ledger.operation))
        XCTAssertTrue(throughScope.observe(.unknown, for: pending))
        XCTAssertEqual(ledger.submissionCount, 2)
        XCTAssertTrue(ledger.hasUnknownSubmissions)
        XCTAssertFalse(ledger.permitsOrdinarySubmission)

        context.document = "fixture:other"
        XCTAssertFalse(boundary.isValid)
        XCTAssertFalse(boundary.canCleanup)
        let decision = try XCTUnwrap(ledger.finish(
            operation: ledger.operation, text: .unchangedByOperation,
            cleanup: .recoveryUnconfirmed, ordinaryRouteValid: false
        ))
        XCTAssertEqual(decision.input, .recoveryRequired)
        XCTAssertEqual(throughScope.claimInput(operation: ledger.operation)?.owner, .recovery)
        XCTAssertNil(ledger.claimInput(operation: ledger.operation))
        XCTAssertFalse(throughScope.observe(.receiverCompleted, for: pending))
        XCTAssertEqual(ledger.decision, decision)
        XCTAssertEqual(context.payloadReads, 0)
    }

    @MainActor
    func testLegacyNilLedgerSurvivesWrappersWithoutWeakeningContextChecks() throws {
        let context = RequestSafetyContext()
        let request = ConversionRequest(expectedWord: "fixture", useSelection: false)
            .checkingTarget { context.current }
            .checkingDocumentContext(context.automatic) { context.automatic }
        XCTAssertNil(request.safetyLedger)
        XCTAssertTrue(request.beginMutation())
        let source = try XCTUnwrap(UnicodeInputSource(identifier: "com.apple.keylayout.ABC", isKeyboardLayout: true))
        let boundary = try XCTUnwrap(UnicodeReadBoundary.capture(
            context: context.unicode, request: request, source: source, activeSource: { source }
        ))
        XCTAssertNil(boundary.request.safetyLedger)
        XCTAssertTrue(boundary.isValid)
        XCTAssertTrue(boundary.canCleanup)
        context.current = false
        XCTAssertFalse(boundary.isValid)
        XCTAssertFalse(boundary.canCleanup)
        XCTAssertEqual(context.payloadReads, 0)
    }
}

/// Метаданные собственного RAM-контекста; чтение текста этому тесту не требуется.
@MainActor
private final class RequestSafetyContext {
    var current = true
    var document = "fixture:one"
    var payloadReads = 0
    var automatic: AutomaticTextContext { .documentProse(document: document) }

    var unicode: UnicodeEnvironment.Context {
        UnicodeEnvironment.Context(
            processID: 123, isCurrent: { self.current },
            rawSnapshot: { _ in self.payloadReads += 1; return nil },
            automaticContext: { self.automatic }, rawDocumentIdentity: { self.document }
        )
    }
}
