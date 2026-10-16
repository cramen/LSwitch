#if DEBUG
import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryRetirementRaceTests: XCTestCase {
    @MainActor
    func testRetirementWaitsForOldTicketThroughCountCopyAndFinalCounters() throws {
        for phase: RecoveryCapturePhase in [.beforeCount, .afterCount, .beforeCapture, .afterCapture] {
            let barrier = RecoveryRetirementBarrier(phase)
            let fixture = try RecoveryRetirementFixture(observePhase: { barrier.observe($0) })
            let event = try fixture.event()
            let router = fixture.router
            DispatchQueue.global().async {
                XCTAssertEqual(router.route(type: .keyDown, event: event), .suppress)
                barrier.finished.signal()
            }
            XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)
            defer { barrier.proceed.signal() }
            XCTAssertFalse(fixture.operation.closeCaptureForStorage(router: router, attachment: fixture.attachment))
            let port = fixture.operation.capturePort
            let seal = try XCTUnwrap(port.trySealForStorage(scope: port.scope))
            XCTAssertNil(router.retiredProof(seal: seal), "Callback ещё не закончил counters")
            XCTAssertEqual(router.route(type: .keyDown, event: event), .suppress)
            barrier.proceed.signal()
            XCTAssertEqual(barrier.finished.wait(timeout: .now() + 2), .success)
            XCTAssertTrue(fixture.operation.closeCaptureForStorage(router: router, attachment: fixture.attachment))
            _ = try fixture.adopt()
            let expectedEvents = phase == .afterCapture ? 1 : 0
            let expectedReads = phase == .beforeCount ? 0 : 1
            XCTAssertEqual(fixture.attachment.counters.payloadCountReads, expectedReads)
            XCTAssertEqual(fixture.attachment.counters.capturedEvents, expectedEvents)
            XCTAssertEqual(fixture.coordinator.metadata?.eventCount, expectedEvents)
            XCTAssertEqual(fixture.coordinator.metadata?.utf16Bytes, expectedEvents * 8)
        }
    }

    @MainActor
    func testBusyPortReturnsPendingWithoutWaitingForAppendAndIncludesAcceptedCopy() throws {
        let fixture = try RecoveryRetirementFixture()
        let port = fixture.operation.capturePort
        let event = try fixture.event()
        let finished = DispatchSemaphore(value: 0)
        fixture.gate.pauseNextAdmission()
        DispatchQueue.global().async {
            XCTAssertEqual(port.capture(event, utf16Units: 4, from: port.scope, at: 1), .accepted)
            finished.signal()
        }
        XCTAssertEqual(fixture.gate.admissionEntered.wait(timeout: .now() + 2), .success)
        defer { fixture.gate.continueAdmission.signal() }
        XCTAssertFalse(fixture.operation.closeCaptureForStorage(router: fixture.router, attachment: fixture.attachment))
        XCTAssertNil(port.trySealForStorage(scope: port.scope), "Try-seal не ждёт удерживающий port callback")
        fixture.gate.continueAdmission.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(fixture.operation.closeCaptureForStorage(router: fixture.router, attachment: fixture.attachment))
        _ = try fixture.adopt()
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
        XCTAssertEqual(fixture.coordinator.metadata?.utf16Bytes, 8)
    }
}
#endif
