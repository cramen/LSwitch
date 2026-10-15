@testable import LSwitchCore
import XCTest

final class ConversionDiagnosticsTests: XCTestCase {
    @MainActor
    func testLatencyStartsAtRawEventAndIncludesTimeBeforeConverter() async throws {
        var now: UInt64 = 300_000_000
        var samples: [ConversionDiagnostics.Sample] = []
        let diagnostics = ConversionDiagnostics(
            bundleID: "test.app", triggerTimestamp: 100_000_000, attempt: 1, automatic: true,
            now: { now }, emit: { samples.append($0) }
        )
        let fixture = ConverterFixture()
        fixture.axEngine.handler = { request in
            XCTAssertTrue(request.diagnostics === diagnostics)
            now = 350_000_000
            return .success(ConversionReceipt(original: "ghbdtn", converted: "привет"))
        }
        let result = await fixture.converter.trigger(
            expectedWord: "ghbdtn", allowUndo: false, triggerTimestamp: 100_000_000, diagnostics: diagnostics
        )
        XCTAssertEqual(result, .converted(original: "ghbdtn", converted: "привет"))
        let final = try XCTUnwrap(samples.last)
        XCTAssertEqual(final.eventNanoseconds, 250_000_000)
        XCTAssertEqual(final.operationNanoseconds, 50_000_000)
        XCTAssertEqual(final.meetsAutomaticLatencyTarget, false)
        XCTAssertEqual(final.mechanism, .accessibility)
        XCTAssertEqual(final.completion, .converted)
        var expectedPhases: [ConversionDiagnostics.Phase] = [
            .requested, .contextCaptured, .holdAcquired, .pendingInputDrained, .engineStarted, .textConfirmed
        ]
        #if DEBUG
        expectedPhases += [.layoutDecision, .layoutObserved, .layoutObserved]
        #endif
        expectedPhases += [.layoutConfirmed, .finished]
        XCTAssertEqual(samples.map(\.phase), expectedPhases)
        XCTAssertFalse(fixture.holdActive)
    }

    @MainActor
    func testFastRejectionAndPartialResultNeverCountAsSuccessfulLatency() async throws {
        for completion: ConversionDiagnostics.Completion in [.blockedBySafety, .failed, .partiallyConverted, .skipped] {
            var samples: [ConversionDiagnostics.Sample] = []
            let diagnostics = ConversionDiagnostics(
                bundleID: "test.app", triggerTimestamp: 10, attempt: 1, automatic: true,
                now: { 20 }, emit: { samples.append($0) }
            )
            diagnostics.complete(completion)
            let final = try XCTUnwrap(samples.last)
            XCTAssertEqual(final.eventNanoseconds, 10)
            XCTAssertNil(final.meetsAutomaticLatencyTarget)
        }
    }

    @MainActor
    func testMissingZeroAndFutureTimestampDoNotBecomeInventedMeasurements() async throws {
        for timestamp: UInt64? in [nil, 0, 201] {
            var samples: [ConversionDiagnostics.Sample] = []
            let diagnostics = ConversionDiagnostics(
                bundleID: "test.app", triggerTimestamp: timestamp, attempt: 1, automatic: true,
                now: { 200 }, emit: { samples.append($0) }
            )
            diagnostics.complete(.converted)
            let final = try XCTUnwrap(samples.last)
            XCTAssertNil(final.eventNanoseconds)
            XCTAssertNil(final.meetsAutomaticLatencyTarget)
            XCTAssertEqual(final.origin, timestamp == nil ? .missing : .invalid)
        }
    }

    @MainActor
    func testOriginalFailureIsNotOverwrittenByGenericCleanupRefusal() async throws {
        var samples: [ConversionDiagnostics.Sample] = []
        let diagnostics = ConversionDiagnostics(
            bundleID: "test.app", triggerTimestamp: 10, attempt: 2, automatic: true,
            now: { 20 }, emit: { samples.append($0) }
        )
        diagnostics.mark(.engineStarted, mechanism: .clipboard)
        XCTAssertFalse(diagnostics.reject(.focusedElementChanged))
        XCTAssertFalse(diagnostics.reject(.requestInvalid))
        diagnostics.complete(.blockedBySafety)
        XCTAssertEqual(samples.filter { $0.phase == .rejected }.count, 1)
        let final = try XCTUnwrap(samples.last)
        XCTAssertEqual(final.reason, .focusedElementChanged)
        XCTAssertEqual(final.mechanism, .clipboard)
        XCTAssertEqual(final.attempt, 2)
        XCTAssertTrue(final.logLine.contains("run=repeat"))
    }

    @MainActor
    func testCompletionDoesNotStoreOrLogTextFromOutcomeAndRunsOnlyOnce() async {
        var samples: [ConversionDiagnostics.Sample] = []
        let diagnostics = ConversionDiagnostics(
            bundleID: "test.app", triggerTimestamp: 10, attempt: 1, automatic: true,
            now: { 20 }, emit: { samples.append($0) }
        )
        diagnostics.finish(.converted(original: "private original", converted: "private converted"))
        diagnostics.complete(.failed)
        diagnostics.reject(.contextChanged)
        XCTAssertEqual(samples.filter { $0.phase == .finished }.count, 1)
        XCTAssertFalse(samples.contains { $0.logLine.contains("private") })
        XCTAssertEqual(samples.last?.completion, .converted)
    }

    @MainActor
    func testQueuedInputInvalidationHasSpecificReasonAndDoesNotStartFallback() async {
        var samples: [ConversionDiagnostics.Sample] = []
        let diagnostics = ConversionDiagnostics(
            bundleID: "test.app", triggerTimestamp: 10, attempt: 1, automatic: true,
            now: { 20 }, emit: { samples.append($0) }
        )
        let fixture = ConverterFixture()
        fixture.axEngine.handler = { _ in
            fixture.converter.notifyOtherKeystroke()
            return .unavailable
        }
        let result = await fixture.converter.trigger(allowUndo: false, triggerTimestamp: 10, diagnostics: diagnostics)
        XCTAssertEqual(result, .blockedBySafety)
        XCTAssertEqual(samples.last?.reason, .generationChanged)
        XCTAssertTrue(fixture.clipboardEngine.requests.isEmpty)
        XCTAssertFalse(fixture.holdActive)
    }

    @MainActor
    func testPartialTISFailureIsDistinguishedFromTextWriteFailure() async {
        var samples: [ConversionDiagnostics.Sample] = []
        let diagnostics = ConversionDiagnostics(
            bundleID: "test.app", triggerTimestamp: 10, attempt: 1, automatic: true,
            now: { 20 }, emit: { samples.append($0) }
        )
        let fixture = ConverterFixture()
        fixture.switchSucceeds = false
        fixture.succeed(fixture.axEngine)
        _ = await fixture.converter.trigger(allowUndo: false, triggerTimestamp: 10, diagnostics: diagnostics)
        XCTAssertEqual(samples.last?.reason, .layoutNotConfirmed)
        XCTAssertEqual(samples.last?.completion, .partiallyConverted)
        XCTAssertTrue(samples.contains { $0.phase == .textConfirmed })
        XCTAssertFalse(samples.contains { $0.phase == .layoutConfirmed })
        XCTAssertNil(samples.last?.meetsAutomaticLatencyTarget)
    }
}
