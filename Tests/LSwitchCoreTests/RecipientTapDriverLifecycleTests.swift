#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class RecipientTapDriverLifecycleTests: XCTestCase {
    @MainActor
    func testStopBeforeStartIsIdempotentAndCannotStartAWorkerAfterward() throws {
        let bridge = try XCTUnwrap(RecoveryRecipientProbeBridge.makeOwnProcess())
        let state = RecipientTapDriverState(bridge: bridge)
        let worker = RecipientTapDriverWorker(state: state, target: bridge.capturedTargetIdentity,
                                              sender: bridge.capturedSenderIdentity)
        XCTAssertTrue(worker.stopAndWait())
        XCTAssertTrue(worker.stopAndWait())
        XCTAssertFalse(worker.startAndWait(), "Stop не должен затем создавать системный tap")
        XCTAssertTrue(state.snapshot.cleanupCompleted)
        XCTAssertFalse(state.snapshot.workerRunning)
        XCTAssertEqual(state.snapshot.loss, .stopped)
    }

    @MainActor
    func testDriverDeinitDoesNotRetainItselfOrRequireAStartedSystemWorker() throws {
        let bridge = try XCTUnwrap(RecoveryRecipientProbeBridge.makeOwnProcess())
        var driver = RecipientTapDriver(bridge: bridge)
        XCTAssertNotNil(driver)
        weak var retained = driver
        driver = nil
        XCTAssertNil(retained)
        XCTAssertTrue(bridge.snapshot.lost)
        XCTAssertEqual(bridge.snapshot.ledgerSubmissionCount, 0)
        XCTAssertFalse(bridge.snapshot.replayAuthorized)
    }

    @MainActor
    func testIdentityMismatchLatchesLossWithoutAutomaticRestoreOfReadiness() throws {
        let fixture = try RecipientTapDriverFixture()
        fixture.state.recordHealth(head: true, tail: true, identityMatches: false)
        fixture.state.recordHealth(head: true, tail: true, identityMatches: true)
        XCTAssertEqual(fixture.state.snapshot.loss, .identityChanged)
        XCTAssertFalse(fixture.state.permitsMutation)
        XCTAssertFalse(fixture.state.isProtectionAvailable)
        fixture.state.withProtection { XCTFail("Новый процесс не наследует старый protected detach") }
    }

    @MainActor
    func testProtectedDetachHoldsDriverGuardUntilTheBodyCompletes() throws {
        let fixture = try RecipientTapDriverFixture()
        let state = fixture.state
        let buffer = InputEventBuffer()
        let token = try XCTUnwrap(buffer.beginHold(at: 0))
        XCTAssertTrue(buffer.intercept(type: .keyDown, event: try fixture.event(isDown: true, owned: false), at: 1))
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let lossStarted = DispatchSemaphore(value: 0)
        let lossFinished = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let result = RecipientDetachResult()
        group.enter()
        DispatchQueue.global().async {
            state.withProtection {
                entered.signal()
                if proceed.wait(timeout: .now() + 2) == .success { result.store(buffer.detach(token: token)) }
            }
            group.leave()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        group.enter()
        DispatchQueue.global().async {
            lossStarted.signal()
            state.markLost(.peerEOF)
            lossFinished.signal()
            group.leave()
        }
        XCTAssertEqual(lossStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(lossFinished.wait(timeout: .now() + .milliseconds(20)), .timedOut)
        proceed.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(result.batch?.eventCount, 1)
        XCTAssertFalse(buffer.isActive)
        XCTAssertEqual(state.snapshot.loss, .peerEOF)
        XCTAssertFalse(state.isProtectionAvailable)
    }
}

private final class RecipientDetachResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HeldInputBatch?

    var batch: HeldInputBatch? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func store(_ batch: HeldInputBatch?) {
        lock.lock()
        value = batch
        lock.unlock()
    }
}
#endif
