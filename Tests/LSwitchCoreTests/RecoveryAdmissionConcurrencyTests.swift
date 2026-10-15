import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryAdmissionConcurrencyTests: XCTestCase {
    @MainActor
    func testPreparingSlotRejectsReentrantReservationAndOFFDuringPreparation() throws {
        for turnOff in [false, true] {
            let target = try XCTUnwrap(RecoveryProcessIdentity(processID: 123, birthSeconds: 1, birthMicroseconds: 2))
            let ledger = ConversionSafetyLedger(generation: 1)
            let gate = RecoveryTestGate()
            var coordinator: RecoveryCoordinator?
            var nested: PreparedRecoveryAdmission?
            coordinator = RecoveryCoordinator(gateFactory: RecoveryGateFactory(prepare: { scope in
                nested = coordinator?.reserve(operation: ledger.operation, target: target)
                if turnOff { coordinator?.setEnabled(false) }
                return gate.prepare(scope)
            }))
            let actual = try XCTUnwrap(coordinator)
            let reservation = actual.reserve(operation: ledger.operation, target: target)
            XCTAssertNil(nested)
            XCTAssertEqual(reservation != nil, !turnOff)
            XCTAssertEqual(gate.preparationCount, 1)
            XCTAssertNil(actual.metadata)
            coordinator = nil
        }
    }

    @MainActor
    func testSealWaitsForAcceptedAppendAndDisallowsAnyLaterAppend() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        let admission = hold.admission
        let binding = hold.binding
        let insideAppend = DispatchSemaphore(value: 0)
        let allowAppend = DispatchSemaphore(value: 0)
        let sealingStarted = DispatchSemaphore(value: 0)
        let sealingFinished = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let results = AdmissionRaceResults()
        group.enter()
        DispatchQueue.global().async {
            let result = admission.admit(utf16Units: 2, binding: binding) {
                insideAppend.signal()
                return allowAppend.wait(timeout: .now() + 3) == .success
            }
            results.setAdmission(result)
            group.leave()
        }
        XCTAssertEqual(insideAppend.wait(timeout: .now() + 2), .success)
        group.enter()
        DispatchQueue.global().async {
            sealingStarted.signal()
            results.setSeal(admission.seal(binding: binding))
            sealingFinished.signal()
            group.leave()
        }
        XCTAssertEqual(sealingStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(sealingFinished.wait(timeout: .now() + .milliseconds(20)), .timedOut)
        allowAppend.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(results.admission, .accepted)
        let sealed = try XCTUnwrap(results.seal)
        XCTAssertEqual(sealed.counts, RecoveryAdmissionCounts(events: 1, utf16Bytes: 4))
        XCTAssertEqual(admission.admit(utf16Units: 1, binding: binding) {
            XCTFail("Append после seal запрещён"); return true
        }, .rejected(.closed))
        XCTAssertTrue(admission.seal(binding: binding) === sealed)
    }

    @MainActor
    func testUnboundAbandonmentFreesSlotButBoundQueueCannotBeAbandoned() throws {
        let fixture = try RecoveryTestFixture()
        let first = try XCTUnwrap(fixture.coordinator.reserve(
            operation: fixture.ledger.operation, target: fixture.target
        ))
        XCTAssertTrue(fixture.coordinator.abandonBeforeHold(first))
        XCTAssertFalse(fixture.coordinator.abandonBeforeHold(first))
        let hold = try fixture.begin()
        XCTAssertFalse(fixture.coordinator.abandonBeforeHold(hold.admission))
        XCTAssertEqual(try hold.append(), .accepted)
        XCTAssertEqual(fixture.coordinator.requestQuit(), .handoverRequired)
    }

    @MainActor
    func testNegativeLifecycleEdgesInvalidatePreparationDespiteABA() throws {
        for edge in [NegativeEdge.off, .permissions, .secureInput] {
            let target = try XCTUnwrap(RecoveryProcessIdentity(processID: 123, birthSeconds: 1, birthMicroseconds: 2))
            let ledger = ConversionSafetyLedger(generation: 1)
            let gate = RecoveryTestGate()
            var coordinator: RecoveryCoordinator?
            var inject = true
            coordinator = RecoveryCoordinator(gateFactory: RecoveryGateFactory(prepare: { scope in
                if inject {
                    inject = false
                    switch edge {
                    case .off:
                        coordinator?.setEnabled(false)
                        coordinator?.setEnabled(true)
                    case .permissions:
                        coordinator?.permissionsLost()
                        coordinator?.permissionsRestored()
                    case .secureInput:
                        coordinator?.secureInputBegan()
                        coordinator?.secureInputEnded()
                    }
                }
                return gate.prepare(scope)
            }))
            let actual = try XCTUnwrap(coordinator)
            XCTAssertNil(actual.reserve(operation: ledger.operation, target: target))
            XCTAssertNil(actual.metadata)
            let fresh = ConversionSafetyLedger(generation: 2)
            XCTAssertNotNil(actual.reserve(operation: fresh.operation, target: target))
            XCTAssertEqual(gate.preparationCount, 2)
            coordinator = nil
        }
    }
}

private enum NegativeEdge { case off, permissions, secureInput }

/// Только результат синхронизации; события и строки здесь отсутствуют.
private final class AdmissionRaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAdmission: RecoveryEventAdmission?
    private var storedSeal: RecoveryAdmissionSeal?

    var admission: RecoveryEventAdmission? {
        lock.lock()
        defer { lock.unlock() }
        return storedAdmission
    }

    var seal: RecoveryAdmissionSeal? {
        lock.lock()
        defer { lock.unlock() }
        return storedSeal
    }

    func setAdmission(_ admission: RecoveryEventAdmission) {
        lock.lock()
        defer { lock.unlock() }
        storedAdmission = admission
    }

    func setSeal(_ seal: RecoveryAdmissionSeal?) {
        lock.lock()
        defer { lock.unlock() }
        storedSeal = seal
    }
}
