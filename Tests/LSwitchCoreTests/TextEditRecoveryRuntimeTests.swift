#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class TextEditRecoveryRuntimeTests: XCTestCase {
    @MainActor
    func testInvocationIsExclusiveAndForeignOrRepeatedFinishDoesNotApplyOutcome() async throws {
        let fixture = TextEditRuntimeTestFixture()
        let foreign = TextEditRuntimeTestFixture()
        let invocation = try XCTUnwrap(fixture.runtime.beginInvocation())
        let foreignInvocation = try XCTUnwrap(foreign.runtime.beginInvocation())
        XCTAssertNil(fixture.runtime.beginInvocation())
        let trace = TextEditRuntimeTestTrace()
        let wrong = await fixture.runtime.finishInvocation(foreignInvocation, outcome: .failed, actions: trace.actions)
        XCTAssertFalse(wrong)
        XCTAssertTrue(trace.entries.isEmpty)
        XCTAssertTrue(fixture.runtime.status.hasUnsettled)
        let finished = await fixture.runtime.finishInvocation(invocation, outcome: .failed, actions: trace.actions)
        XCTAssertTrue(finished)
        XCTAssertEqual(trace.entries, ["outcome", "reset"])
        XCTAssertFalse(fixture.runtime.status.hasUnsettled)
        let next = try XCTUnwrap(fixture.runtime.beginInvocation())
        XCTAssertNotEqual(next, invocation)
        let repeated = await fixture.runtime.finishInvocation(invocation, outcome: .failed, actions: trace.actions)
        XCTAssertFalse(repeated)
        XCTAssertEqual(fixture.runtime.attempt?.invocation, next)
        XCTAssertEqual(trace.entries, ["outcome", "reset"])
        XCTAssertEqual(fixture.tapReads, 0)
    }

    @MainActor
    func testReentrantSafetyCheckCannotOverwriteAlreadyAcceptedInvocation() throws {
        let fixture = TextEditRuntimeTestFixture()
        var nested: TextEditRecoveryInvocation?
        fixture.onSafety = {
            fixture.onSafety = {}
            nested = fixture.runtime.beginInvocation()
        }
        let outer = fixture.runtime.beginInvocation()
        XCTAssertEqual((outer == nil ? 0 : 1) + (nested == nil ? 0 : 1), 1)
        let accepted = try XCTUnwrap(outer ?? nested)
        XCTAssertEqual(fixture.runtime.attempt?.invocation, accepted)
        XCTAssertTrue(fixture.runtime.status.hasUnsettled)
        XCTAssertEqual(fixture.tapReads, 0)
    }

    @MainActor
    func testStateNotificationReentryCannotStartAnotherInvocationAndInterruptionBlocksFactory() async throws {
        let fixture = TextEditRuntimeTestFixture()
        fixture.runtime.onStateChange = {
            fixture.runtime.onStateChange = {}
            XCTAssertNil(fixture.runtime.beginInvocation())
            fixture.runtime.invalidate(.focusChanged)
        }
        let invocation = try XCTUnwrap(fixture.runtime.beginInvocation())
        let outcome = await fixture.converter.trigger()
        XCTAssertEqual(outcome, .blockedBySafety)
        XCTAssertEqual(fixture.runtime.diagnosticStage, TextEditRecoveryStage.interrupted.rawValue)
        XCTAssertEqual(fixture.tapReads, 0)
        XCTAssertTrue(fixture.engine.requests.isEmpty)
        XCTAssertEqual(fixture.legacyHoldCalls, 0)
        let trace = TextEditRuntimeTestTrace()
        let finished = await fixture.runtime.finishInvocation(invocation, outcome: outcome, actions: trace.actions)
        XCTAssertTrue(finished)
        XCTAssertEqual(trace.entries, ["outcome", "reset"])
    }

    @MainActor
    func testUnavailableUnsafeAndUnsupportedFactoriesNeverUseLegacyOrSystemProfile() async throws {
        for reason in RuntimeFactoryRefusal.allCases {
            let fixture = TextEditRuntimeTestFixture(document: try reason.document())
            if reason == .stoppedTap { fixture.tap = EventTapCore { _ in XCTFail("Нет реального callback") } }
            if reason == .wrongApplication { fixture.bundleID = "com.example.OtherEditor" }
            let invocation = try XCTUnwrap(fixture.runtime.beginInvocation())
            if reason == .unsafe { fixture.safe = false }
            let outcome = await fixture.converter.trigger()
            XCTAssertEqual(outcome, .blockedBySafety, reason.rawValue)
            XCTAssertEqual(fixture.factoryCalls, 1)
            XCTAssertEqual(fixture.tapReads, reason == .missingTap || reason == .stoppedTap ? 1 : 0)
            XCTAssertEqual(fixture.runtime.diagnosticStage, TextEditRecoveryStage.invocation.rawValue)
            XCTAssertNil(fixture.runtime.attempt?.adapter)
            XCTAssertNil(fixture.runtime.attempt?.driver)
            XCTAssertTrue(fixture.engine.requests.isEmpty)
            XCTAssertEqual(fixture.legacyHoldCalls, 0)
            XCTAssertEqual(fixture.legacyReleaseCalls, 0)
            XCTAssertEqual(fixture.layoutWrites, 0)
            XCTAssertEqual(fixture.successSignals, 0)
            XCTAssertFalse(fixture.runtime.owner.isOccupied)
            XCTAssertNil(fixture.runtime.metadata)
            let trace = TextEditRuntimeTestTrace()
            let finished = await fixture.runtime.finishInvocation(invocation, outcome: outcome, actions: trace.actions)
            XCTAssertTrue(finished)
            XCTAssertEqual(trace.entries, ["outcome", "reset"])
            XCTAssertFalse(fixture.runtime.status.hasPending)
            XCTAssertFalse(fixture.runtime.status.hasUnsettled)
        }
    }

    @MainActor
    func testOutcomeReentryCannotAcquireInvocationOrAuthorizeQuitBeforeReset() async throws {
        let fixture = TextEditRuntimeTestFixture()
        let invocation = try XCTUnwrap(fixture.runtime.beginInvocation())
        let trace = TextEditRuntimeTestTrace()
        trace.onOutcome = {
            XCTAssertNil(fixture.runtime.beginInvocation())
            guard case .handoverRequired = fixture.runtime.quitActions.request() else {
                return XCTFail("Outcome ещё не завершил invocation")
            }
            XCTAssertFalse(fixture.runtime.quitAuthorized)
        }
        let finished = await fixture.runtime.finishInvocation(invocation, outcome: .failed, actions: trace.actions)
        XCTAssertTrue(finished)
        XCTAssertEqual(trace.entries, ["outcome", "reset"])
        XCTAssertNotNil(fixture.runtime.beginInvocation())
    }

    @MainActor
    func testQuitReadinessDoesNotAuthorizeShutdownAndExplicitAllowedDecisionIsMonotonic() async {
        let fixture = TextEditRuntimeTestFixture()
        let prepared = await fixture.runtime.prepareForQuit()
        XCTAssertTrue(prepared)
        let premature = await fixture.runtime.shutdownAfterQuitDecision()
        XCTAssertFalse(premature)
        guard case .allowed = fixture.runtime.quitActions.request() else { return XCTFail("Нет pending очереди") }
        XCTAssertTrue(fixture.runtime.quitAuthorized)
        XCTAssertNil(fixture.runtime.beginInvocation())
        let completed = await fixture.runtime.shutdownAfterQuitDecision()
        XCTAssertTrue(completed)
        let repeated = await fixture.runtime.shutdownAfterQuitDecision()
        XCTAssertTrue(repeated)
        XCTAssertEqual(fixture.tapReads, 0)
    }

    @MainActor
    func testOwnerReservationAndCancelledPreparationCannotBeMistakenForQuitPermission() async throws {
        let fixture = TextEditRuntimeTestFixture()
        let admission = try XCTUnwrap(fixture.runtime.owner.reserve())
        XCTAssertNil(fixture.runtime.beginInvocation())
        guard case .handoverRequired = fixture.runtime.quitActions.request() else {
            return XCTFail("Owner всё ещё содержит reservation")
        }
        let prepared = await fixture.runtime.prepareForQuit()
        XCTAssertFalse(prepared)
        XCTAssertFalse(fixture.runtime.quitAuthorized)
        fixture.runtime.owner.finishInvocation(admission)
        let invocation = try XCTUnwrap(fixture.runtime.beginInvocation())
        let cancelled = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.runtime.prepareForQuit()
        }.value
        XCTAssertFalse(cancelled)
        XCTAssertEqual(fixture.runtime.attempt?.invocation, invocation)
        XCTAssertTrue(fixture.runtime.status.hasUnsettled)
        XCTAssertFalse(fixture.runtime.quitAuthorized)
        XCTAssertNil(fixture.runtime.metadata)
        XCTAssertEqual(fixture.tapReads, 0)
    }
}

private enum RuntimeFactoryRefusal: String, CaseIterable {
    case missingTap, stoppedTap, unsafe, wrongApplication, nonFileURL

    func document() throws -> URL {
        if self == .nonFileURL { return try XCTUnwrap(URL(string: "https://example.invalid/fixture.txt")) }
        return URL(fileURLWithPath: "/private/tmp/LSwitch-owned-runtime-fixture.txt")
    }
}

@MainActor
private final class TextEditRuntimeTestFixture {
    let document: URL
    let engine = StubEngine()
    let rules = AppRules(defaults: UserDefaults(suiteName: "runtime-\(UUID().uuidString)") ?? .standard)
    var safe = true
    var tap: EventTapCore?
    var bundleID = "com.apple.TextEdit"
    var onSafety: () -> Void = {}
    var tapReads = 0
    var factoryCalls = 0
    var legacyHoldCalls = 0
    var legacyReleaseCalls = 0
    var layoutWrites = 0
    var successSignals = 0

    init(document: URL = URL(fileURLWithPath: "/private/tmp/LSwitch-owned-runtime-fixture.txt")) {
        self.document = document
    }

    lazy var runtime = TextEditRecoveryRuntime(testDocument: document, eventTap: { [weak self] in
        self?.tapReads += 1
        return self?.tap
    }, currentSafety: { [weak self] in
        guard let self else { return false }
        self.onSafety()
        return self.safe
    })

    lazy var converter = Converter(
        currentLayout: { .english }, switchLayout: { [weak self] _ in self?.layoutWrites += 1; return true },
        appRules: rules, undoStore: UndoStore(), frontmostBundleID: { [weak self] in self?.bundleID },
        makeAXEngine: { [engine] in engine }, makeClipboardEngine: { [engine] in engine },
        recoverySessionFactory: { [weak self] context in
            guard let self else { return nil }
            self.factoryCalls += 1
            return await self.runtime.makeSession(context)
        }, recoveryOwner: runtime.owner, captureContext: { { true } },
        beginInputHold: { [weak self] in self?.legacyHoldCalls += 1; return true },
        endInputHold: { [weak self] in self?.legacyReleaseCalls += 1 },
        onConverted: { [weak self] in self?.successSignals += 1 }
    )
}

@MainActor
private final class TextEditRuntimeTestTrace {
    var entries: [String] = []
    var onOutcome: () -> Void = {}

    var actions: TextEditRecoveryInvocationActions {
        .init(applyOutcome: { _ in self.entries.append("outcome"); self.onOutcome() },
              reset: { self.entries.append("reset") },
              consume: { _ in XCTFail("Ни одного logical/native event в этом fixture") })
    }
}
#endif
