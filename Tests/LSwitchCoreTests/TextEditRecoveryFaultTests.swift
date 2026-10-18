#if DEBUG
import ApplicationServices
import Foundation
@testable import LSwitchCore
import XCTest

final class TextEditRecoveryFaultTests: XCTestCase {
    @MainActor
    func testRealConverterSelectionThenMissingSnapshotKeepsTextAndStickyRecoveryEvidence() async throws {
        let editor = try AXProfileFixture()
        let original = editor.environment
        let memory = TextEditFaultMemory()
        let fault = memory.fixture()
        memory.onPause = { memory.prefix() }
        let access = TextEditRecoveryFaultAccess(original: editor.access, fixture: fault)
        let environment = AXProfileEnvironment(activeSource: original.activeSource,
            focusedElement: original.focusedElement, isProtected: original.isProtected, context: original.context,
            snapshot: { fault.snapshot($0, canRead: $1, original: original.snapshot) })
        let profile = try XCTUnwrap(AXObservationProfile.prepareTextEdit(
            element: editor.access.model.element, environment: environment))
        let ledger = ConversionSafetyLedger(generation: 1, profile: profile.binding)
        let converter = AXTextConverter(access: access, observationProfile: profile)
        let result = await converter.performWithEvidence(editor.request(ledger))
        XCTAssertEqual(result.result, .failed)
        XCTAssertEqual(result.cleanup, .recoveryUnconfirmed)
        XCTAssertEqual(ledger.submissionCount, 1)
        XCTAssertTrue(ledger.hasProfileFault)
        XCTAssertEqual(editor.access.model.selectionWrites.count, 1)
        XCTAssertEqual(editor.access.model.textWrites, 0)
        XCTAssertEqual(editor.access.model.value, "ghbdtn ")
        XCTAssertEqual(editor.access.model.currentSelection, NSRange(location: 0, length: 7))
        XCTAssertEqual(fault.report.phase, .injected)
        XCTAssertTrue(fault.report.selectedRangeObserved)
        XCTAssertEqual(fault.report.capturedEvents, 2)
        XCTAssertEqual(fault.report.blockedWrites, 0, "Движок сам не запросил второй setter")
        let reads = editor.snapshotReads
        XCTAssertNil(fault.snapshot(editor.access.model.element, canRead: { true }, original: original.snapshot))
        XCTAssertEqual(editor.snapshotReads, reads, "После fault original provider больше не вызывается")
        XCTAssertFalse(profile.isCurrent(ledger: ledger))
    }

    @MainActor
    func testForwardedPreparedWriteUsesOneOriginalTokenAndNeverForwardsAnotherSetter() throws {
        let original = AXSafetyTestAccess("ghbdtn")
        let memory = TextEditFaultMemory()
        let fault = memory.fixture()
        let access = TextEditRecoveryFaultAccess(original: original, fixture: fault)
        let ledger = ConversionSafetyLedger(generation: 1)
        let token = try XCTUnwrap(ledger.willSubmit(.selection, operation: ledger.operation))
        original.beforeWrite = { XCTAssertEqual($0, token) }
        let first = try XCTUnwrap(access.prepareSelection(NSRange(location: 0, length: 6), in: original.model.element))
        XCTAssertEqual(first.submit(beforeSend: { token })?.status, .success)
        XCTAssertNil(first.submit(beforeSend: { XCTFail("Повторный submit"); return token }))
        let second = try XCTUnwrap(access.prepareSelection(NSRange(location: 6, length: 0), in: original.model.element))
        XCTAssertEqual(second.submit(beforeSend: { token })?.status, .cannotComplete)
        XCTAssertNil(access.prepareReplacement("привет", in: original.model.element))
        XCTAssertEqual(ledger.submissionCount, 1)
        XCTAssertEqual(original.model.selectionWrites.count, 1)
        XCTAssertEqual(original.model.textWrites, 0)
        XCTAssertEqual(fault.report.blockedWrites, 2)
    }

    @MainActor
    func testMissingPrefixStopsAtOriginalLeaseOrOneHundredMillisecondsWithoutFalseInjection() async {
        for deadline: UInt64 in [40_000_001, 400_000_001] {
            let memory = TextEditFaultMemory()
            let fault = memory.fixture(deadline: deadline)
            XCTAssertTrue(fault.beginSelection())
            fault.didSelect(.success)
            await fault.waitForPrefix(selectionMatches: { true })
            XCTAssertEqual(memory.time, min(deadline, 100_000_001))
            XCTAssertEqual(fault.report.phase, .inconclusive)
            XCTAssertEqual(fault.report.capturedEvents, 0)
            XCTAssertFalse(fault.beginSelection())
        }
    }

    @MainActor
    func testModifierEventsOrMissingPayloadCannotMasqueradeAsHeldPrefix() async {
        let counters: [RecoveryCaptureCounters] = [
            .init(capturedEvents: 2, capturedUTF16Bytes: 0, rejectedEvents: 0, payloadCountReads: 0),
            .init(capturedEvents: 2, capturedUTF16Bytes: 0, rejectedEvents: 0, payloadCountReads: 2),
            .init(capturedEvents: 1, capturedUTF16Bytes: 2, rejectedEvents: 0, payloadCountReads: 1)
        ]
        for count in counters {
            let memory = TextEditFaultMemory()
            memory.counters = count
            let fault = memory.fixture()
            XCTAssertTrue(fault.beginSelection())
            fault.didSelect(.success)
            await fault.waitForPrefix(selectionMatches: { true })
            XCTAssertEqual(fault.report.phase, .inconclusive)
        }
    }

    @MainActor
    func testCancellationOrLostCaptureCannotBecomeInjectedWithAnOtherwiseCompletePrefix() async {
        for cancelled in [false, true] {
            let memory = TextEditFaultMemory()
            let fault = memory.fixture()
            XCTAssertTrue(fault.beginSelection())
            fault.didSelect(.success)
            if cancelled {
                memory.prefix()
                let task = Task { await fault.waitForPrefix(selectionMatches: { true }) }
                task.cancel()
                await task.value
            } else {
                memory.onPause = { memory.prefix(); memory.current = false }
                await fault.waitForPrefix(selectionMatches: { true })
            }
            XCTAssertEqual(fault.report.phase, .inconclusive)
            XCTAssertFalse(fault.beginSelection())
        }
    }

    @MainActor
    func testSelectionChangedWhileWaitingForPrefixCannotQualifyTheOriginalP1() async {
        let memory = TextEditFaultMemory()
        let fault = memory.fixture()
        var selectionMatches = true
        memory.onPause = { selectionMatches = false; memory.prefix() }
        XCTAssertTrue(fault.beginSelection())
        fault.didSelect(.success)
        await fault.waitForPrefix(selectionMatches: { selectionMatches })
        XCTAssertEqual(fault.report.phase, .inconclusive)
        XCTAssertFalse(fault.report.selectedRangeObserved)
        XCTAssertEqual(fault.report.capturedEvents, 2)
        XCTAssertFalse(fault.beginSelection())
    }

    @MainActor
    func testUnobservedOrUnsuccessfulSelectionCannotQualifyTheFault() async {
        for succeeded in [false, true] {
            let memory = TextEditFaultMemory()
            memory.prefix()
            let fault = memory.fixture()
            XCTAssertTrue(fault.beginSelection())
            fault.didSelect(succeeded ? .success : .cannotComplete)
            await fault.waitForPrefix(selectionMatches: { false })
            XCTAssertEqual(fault.report.phase, .inconclusive)
            XCTAssertFalse(fault.report.selectedRangeObserved)
            XCTAssertEqual(memory.time, 1)
        }
    }
}

@MainActor
private final class TextEditFaultMemory {
    var time: UInt64 = 1
    var current = true
    var counters = RecoveryCaptureCounters(
        capturedEvents: 0, capturedUTF16Bytes: 0, rejectedEvents: 0, payloadCountReads: 0)
    var onPause: () -> Void = {}

    func prefix() {
        counters = .init(capturedEvents: 2, capturedUTF16Bytes: 4, rejectedEvents: 0, payloadCountReads: 2)
    }

    func fixture(deadline: UInt64 = 400_000_001) -> TextEditRecoveryFaultFixture {
        let fault = TextEditRecoveryFaultFixture(now: { self.time }, pause: {
            self.time += 10_000_000
            self.onPause()
        })
        fault.bind(deadline: deadline, isCurrent: { self.current }, counters: { self.counters })
        return fault
    }
}
#endif
