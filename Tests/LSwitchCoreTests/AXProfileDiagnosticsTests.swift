import ApplicationServices
import Foundation
@testable import LSwitchCore
import XCTest

final class AXProfileDiagnosticsTests: XCTestCase {
    @MainActor
    func testMeasurementPreservesGuardOrderAndReadOnlyReportsDoNotCallEnvironment() throws {
        let fixture = try AXProfileFixture()
        let original = fixture.environment
        var calls: [String] = []
        let environment = AXProfileEnvironment(activeSource: {
            calls.append("source"); return original.activeSource()
        }, focusedElement: {
            calls.append("focus"); return original.focusedElement()
        }, isProtected: { element in
            calls.append("protected"); return original.isProtected(element)
        }, context: { element in
            calls.append("context"); return original.context(element)
        }, snapshot: original.snapshot)
        let profile = try XCTUnwrap(AXObservationProfile.prepareTextEdit(
            element: fixture.access.model.element, environment: environment
        ))
        XCTAssertEqual(profile.diagnosticReport.context.count, 0, "Prepare не входит в bound-profile измерения")
        calls.removeAll()
        let ledger = ConversionSafetyLedger(generation: 1, profile: profile.binding)
        XCTAssertTrue(profile.bind(to: fixture.access.model.element, ledger: ledger, isValid: {
            calls.append("request"); return true
        }))
        XCTAssertEqual(calls, ["request", "source", "protected", "focus", "context",
                               "protected", "focus", "source", "request"])
        let before = calls
        let report = profile.diagnosticReport
        XCTAssertEqual(report.requestIsValid.count, 2)
        XCTAssertEqual(report.source.count, 2)
        XCTAssertEqual(report.protectedField.count, 2)
        XCTAssertEqual(report.focus.count, 2)
        XCTAssertEqual(report.context.count, 1)
        XCTAssertEqual(report.snapshotInclusive.count, 0)
        XCTAssertNil(report.profileFault)
        XCTAssertEqual(profile.diagnosticReport, report)
        XCTAssertEqual(calls, before)
    }

    @MainActor
    func testInclusiveSnapshotRecordsNestedCategoriesWithoutChangingReturnValue() {
        let diagnostics = AXProfileDiagnostics()
        let result = diagnostics.measure(.snapshot) {
            diagnostics.measure(.context) { 42 }
        }
        XCTAssertEqual(result, 42)
        let report = diagnostics.report(fault: nil)
        XCTAssertEqual(report.snapshotInclusive.count, 1)
        XCTAssertEqual(report.context.count, 1)
        XCTAssertGreaterThanOrEqual(report.snapshotInclusive.nanoseconds, report.context.nanoseconds)
        XCTAssertEqual(report.requestIsValid.count, 0)
    }

    @MainActor
    func testFailedSnapshotIsTimedAndReportUsesCurrentLedgerFaultWithoutNewReads() throws {
        let fixture = try AXProfileFixture()
        let operation = try fixture.prepare()
        XCTAssertTrue(operation.profile.bind(to: fixture.access.model.element, ledger: operation.ledger,
                                            isValid: { true }))
        fixture.missingSnapshot = true
        XCTAssertNil(operation.profile.read(expected: nil, ledger: operation.ledger))
        let report = operation.profile.diagnosticReport
        XCTAssertEqual(report.snapshotInclusive.count, 1)
        XCTAssertEqual(report.profileFault, .snapshotUnavailable)
        let reads = fixture.snapshotReads
        XCTAssertEqual(operation.profile.diagnosticReport, report)
        XCTAssertFalse(operation.profile.isCurrent(ledger: operation.ledger))
        XCTAssertEqual(operation.profile.diagnosticReport, report)
        XCTAssertEqual(fixture.snapshotReads, reads)
    }

    @MainActor
    func testExternalFaultAndEarlyRefusalDoNotRunLaterGuardCategories() throws {
        let fixture = try AXProfileFixture()
        let profile = try XCTUnwrap(fixture.profile())
        let ledger = ConversionSafetyLedger(generation: 1, profile: profile.binding)
        XCTAssertFalse(profile.bind(to: fixture.access.model.element, ledger: ledger, isValid: { false }))
        let report = profile.diagnosticReport
        XCTAssertEqual(report.requestIsValid.count, 1)
        XCTAssertEqual(report.source.count, 0)
        XCTAssertEqual(report.context.count, 0)
        XCTAssertEqual(report.profileFault, .contextChanged)
        let next = try fixture.prepare()
        XCTAssertTrue(next.profile.bind(to: fixture.access.model.element, ledger: next.ledger, isValid: { true }))
        let before = next.profile.diagnosticReport
        XCTAssertTrue(next.ledger.recordProfileFault(.preparationFailed, operation: next.ledger.operation))
        let after = next.profile.diagnosticReport
        XCTAssertEqual(after.profileFault, .preparationFailed)
        XCTAssertEqual(before.context, after.context)
        XCTAssertEqual(before.requestIsValid, after.requestIsValid)
    }

    @MainActor
    func testDiagnosticLedgerReferenceDoesNotRetainFinishedOperation() throws {
        let fixture = try AXProfileFixture()
        let profile = try XCTUnwrap(fixture.profile())
        var ledger: ConversionSafetyLedger? = ConversionSafetyLedger(generation: 1, profile: profile.binding)
        weak var observed = ledger
        XCTAssertTrue(profile.bind(to: fixture.access.model.element, ledger: try XCTUnwrap(ledger), isValid: { true }))
        ledger = nil
        XCTAssertNil(observed)
        XCTAssertNil(profile.diagnosticReport.profileFault)
        XCTAssertEqual(profile.diagnosticReport.context.count, 1)
    }

    func testTimingSaturatesInsteadOfWrapping() {
        var timing = AXProfileTiming()
        timing.record(nanoseconds: UInt64.max)
        timing.record(nanoseconds: 1)
        XCTAssertEqual(timing.count, 2)
        XCTAssertEqual(timing.nanoseconds, UInt64.max)
    }
}
