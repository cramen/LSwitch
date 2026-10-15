import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryCapturePortTests: XCTestCase {
    @MainActor
    func testEventLimitKeepsAllAcceptedCopiesAndRejectsOverflowBeforeAppend() throws {
        let fixture = try RecoveryOperationFixture()
        let port = fixture.operation.capturePort
        let event = try RecoveryOperationFixture.event("a")
        for index in 0..<PreparedRecoveryAdmission.maximumEvents {
            let expected: RecoveryEventAdmission = index == PreparedRecoveryAdmission.maximumEvents - 1
                ? .acceptedRequiringHandover(.eventLimit) : .accepted
            XCTAssertEqual(port.capture(event, utf16Units: 1, from: port.scope, at: 1), expected)
        }
        XCTAssertEqual(try fixture.append("overflow"), .rejected(.eventLimit))
        let changed = Array("changed".utf16)
        event.keyboardSetUnicodeString(stringLength: changed.count, unicodeString: changed)
        XCTAssertEqual(fixture.operation.closeCapture(), .detached(.init(events: 256, utf16Bytes: 512)))
        fixture.finishRecovery()
        guard case .adopted = fixture.operation.adopt(in: fixture.coordinator, reason: .admissionStopped) else {
            return XCTFail("Квота не должна обрезать принятый префикс")
        }
        XCTAssertEqual(try fixture.revealedTexts(), Array(repeating: "a", count: 256))
    }

    @MainActor
    func testInvalidOrOversizedDeclaredCostCannotAppendOrLosePreviousAcceptedEvent() throws {
        for cost in [-1, Int.max] {
            let fixture = try RecoveryOperationFixture()
            let port = fixture.operation.capturePort
            XCTAssertEqual(try fixture.append("kept"), .accepted)
            let failure: RecoveryAdmissionFailure = cost < 0 ? .invalidCost : .payloadLimit
            let event = try RecoveryOperationFixture.event("not accepted")
            XCTAssertEqual(port.capture(event, utf16Units: cost, from: port.scope, at: 1), .rejected(failure))
            XCTAssertEqual(try fixture.append("late"), .rejected(failure))
            XCTAssertEqual(fixture.operation.closeCapture(), .detached(.init(events: 1, utf16Bytes: 8)))
            fixture.finishRecovery()
            guard case .adopted = fixture.operation.adopt(in: fixture.coordinator, reason: .admissionStopped) else {
                return XCTFail("Ошибка стоимости не удаляет прежний префикс")
            }
            XCTAssertEqual(try fixture.revealedTexts(), ["kept"])
        }
    }

    @MainActor
    func testInvalidationDuringHandoverPreparationDoesNotPublishCapturePort() throws {
        let fixture = try RecoveryTestFixture()
        let admission = try XCTUnwrap(fixture.coordinator.reserve(
            operation: fixture.ledger.operation, target: fixture.target
        ))
        let gate = RecoveryCaptureTestGate()
        let factory = RecoveryCaptureHandoverFactory(prepare: { scope, tap in
            _ = fixture.ledger.finishUsingRecordedCleanup(
                operation: fixture.ledger.operation, text: .unknown, ordinaryRouteValid: false
            )
            return gate.prepared(scope, tap: tap)
        })
        XCTAssertNil(RecoveryOperation.prepare(
            ledger: fixture.ledger, admission: admission, tapIdentifier: UUID(), at: 0, handoverFactory: factory
        ))
        XCTAssertTrue(fixture.coordinator.abandonBeforeHold(admission))
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
        XCTAssertNil(fixture.coordinator.metadata)
    }
}
