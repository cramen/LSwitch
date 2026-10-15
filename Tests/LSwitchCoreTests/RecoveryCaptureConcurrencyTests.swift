import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryCaptureConcurrencyTests: XCTestCase {
    @MainActor
    func testSealFinishesBeforeGateProtectedDetachAvoidingAdmissionGateLockInversion() throws {
        let fixture = try RecoveryOperationFixture()
        XCTAssertEqual(try fixture.append("kept"), .accepted)
        let port = fixture.operation.capturePort
        let gate = fixture.gate
        let admission = fixture.admission
        let results = RecoveryCaptureRaceResults()
        let group = DispatchGroup()
        gate.pauseNextAdmission()
        group.enter()
        DispatchQueue.global().async {
            results.setReadiness(admission.permitsMutation(for: port.scope.binding))
            group.leave()
        }
        XCTAssertEqual(gate.admissionEntered.wait(timeout: .now() + 2), .success)
        group.enter()
        DispatchQueue.global().async {
            results.setClosure(port.close(scope: port.scope))
            group.leave()
        }
        // Нельзя взять gate lock, пока seal ждёт удерживаемый admission lock.
        XCTAssertEqual(gate.protectionEntered.wait(timeout: .now() + .milliseconds(20)), .timedOut)
        gate.continueAdmission.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(results.readiness, true)
        XCTAssertEqual(results.closure, .detached(.init(events: 1, utf16Bytes: 8)))
    }

    @MainActor
    func testConcurrentCloseWaitsForAcceptedAppendAndKeepsOneCompleteBatch() throws {
        let fixture = try RecoveryOperationFixture()
        let port = fixture.operation.capturePort
        let gate = fixture.gate
        let results = RecoveryCaptureRaceResults()
        let group = DispatchGroup()
        gate.pauseNextAdmission()
        group.enter()
        DispatchQueue.global().async {
            if let event = try? RecoveryOperationFixture.event("kept") {
                results.setAdmission(port.capture(event, utf16Units: 4, from: port.scope, at: 1))
            }
            group.leave()
        }
        XCTAssertEqual(gate.admissionEntered.wait(timeout: .now() + 2), .success)
        group.enter()
        DispatchQueue.global().async {
            results.setClosure(port.close(scope: port.scope))
            group.leave()
        }
        XCTAssertEqual(gate.protectionEntered.wait(timeout: .now() + .milliseconds(20)), .timedOut)
        gate.continueAdmission.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(results.admission, .accepted)
        XCTAssertEqual(results.closure, .detached(.init(events: 1, utf16Bytes: 8)))
        XCTAssertEqual(try fixture.append("late"), .rejected(.closed))
        fixture.finishRecovery()
        guard case .adopted = fixture.operation.adopt(in: fixture.coordinator, reason: .admissionStopped) else {
            return XCTFail("Один полный batch должен перейти в RAM coordinator")
        }
        XCTAssertEqual(try fixture.revealedTexts(), ["kept"])
    }
}

/// Только результаты синхронизации, без CGEvent или payload.
private final class RecoveryCaptureRaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReadiness: Bool?
    private var storedClosure: RecoveryCaptureClosure?
    private var storedAdmission: RecoveryEventAdmission?

    var readiness: Bool? { locked { storedReadiness } }
    var closure: RecoveryCaptureClosure? { locked { storedClosure } }
    var admission: RecoveryEventAdmission? { locked { storedAdmission } }

    func setReadiness(_ value: Bool) { locked { storedReadiness = value } }
    func setClosure(_ value: RecoveryCaptureClosure) { locked { storedClosure = value } }
    func setAdmission(_ value: RecoveryEventAdmission) { locked { storedAdmission = value } }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
