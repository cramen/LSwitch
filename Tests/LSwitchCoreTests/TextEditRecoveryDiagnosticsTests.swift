#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class TextEditRecoveryDiagnosticsTests: XCTestCase {
    @MainActor
    func testCompletedRuntimeKeepsOnlyValueReportAndNewInvocationCannotReceiveStaleFinish() async throws {
        let editor = try AXProfileFixture()
        var profile: AXObservationProfile? = try XCTUnwrap(editor.profile())
        weak var observedProfile = profile
        let runtime = TextEditRecoveryRuntime(testDocument: URL(fileURLWithPath: "/tmp/owned.txt"),
                                              eventTap: { nil }, currentSafety: { true })
        let invocation = try XCTUnwrap(runtime.beginInvocation())
        var attempt = runtime.attempt
        attempt?.profile = profile
        attempt?.logicalFailure = .expired
        let ledger = ConversionSafetyLedger(generation: 1, profile: try XCTUnwrap(profile).binding)
        XCTAssertTrue(profile?.bind(to: editor.access.model.element, ledger: ledger, isValid: { true }) == true)
        XCTAssertTrue(ledger.recordProfileFault(.snapshotUnavailable, operation: ledger.operation))
        let reads = editor.snapshotReads
        let finished = await runtime.finishInvocation(invocation, outcome: .failed,
            actions: .init(applyOutcome: { _ in }, reset: {}, consume: { _ in }))
        XCTAssertTrue(finished)
        XCTAssertEqual(runtime.profileReport?.profileFault, "snapshotUnavailable")
        XCTAssertEqual(runtime.profileReport?.logicalFailure, "expired")
        XCTAssertEqual(runtime.profileReport?.requestIsValid.count, 2)
        XCTAssertEqual(editor.snapshotReads, reads)
        XCTAssertNotNil(runtime.beginInvocation())
        runtime.recordProfileReport(try XCTUnwrap(attempt), finish: .reset(.stopped))
        XCTAssertNil(runtime.profileReport, "Старый finish не переносит статистику в новую invocation")
        attempt = nil
        profile = nil
        XCTAssertNil(observedProfile, "Value отчёт не удерживает профиль или engine")
    }

    func testScopedLogicalFailureReadDoesNotExpireOrExposeAnotherLease() throws {
        let state = EventProcessingLeaseState()
        let scope = try EventProcessingTestFixture.scope()
        let first = try XCTUnwrap(state.begin(scope: scope, at: 1))
        XCTAssertNil(state.failure(for: first))
        XCTAssertEqual(state.metadata.failure, nil)
        state.invalidate(.payloadLimit, lease: first)
        XCTAssertEqual(state.failure(for: first), .payloadLimit)
        XCTAssertTrue(state.claimFinish(first, disposition: .discard, at: 2))
        guard case .finished(.reset(.payloadLimit)) = state.next(first, at: 2) else {
            return XCTFail("Нужна терминальная причина первой lease")
        }
        let second = try XCTUnwrap(state.begin(scope: scope, at: 3))
        state.invalidate(.stopped, lease: second)
        XCTAssertNil(state.failure(for: first))
        XCTAssertEqual(state.failure(for: second), .stopped)
    }
}
#endif
