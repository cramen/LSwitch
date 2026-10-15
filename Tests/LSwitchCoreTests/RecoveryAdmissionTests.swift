import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryAdmissionTests: XCTestCase {
    @MainActor
    func testDefaultFactoryCannotReserveAndProcessBirthIsRequired() throws {
        XCTAssertNil(RecoveryProcessIdentity(processID: 0, birthSeconds: 1, birthMicroseconds: 0))
        XCTAssertNil(RecoveryProcessIdentity(processID: 123, birthSeconds: 0, birthMicroseconds: 0))
        XCTAssertNil(RecoveryProcessIdentity(processID: 123, birthSeconds: 1, birthMicroseconds: 1_000_000))
        let fixture = try RecoveryTestFixture()
        let coordinator = RecoveryCoordinator()
        XCTAssertNil(coordinator.reserve(operation: fixture.ledger.operation, target: fixture.target))
        XCTAssertNil(coordinator.metadata)
    }

    @MainActor
    func testGatePreparedBeforeHoldCannotAdmitUntilPureBinding() throws {
        let fixture = try RecoveryTestFixture()
        let prepared = try XCTUnwrap(fixture.coordinator.reserve(
            operation: fixture.ledger.operation, target: fixture.target
        ))
        XCTAssertEqual(fixture.gate.preparationCount, 1)
        let buffer = InputEventBuffer()
        let token = try XCTUnwrap(buffer.beginHold(at: 0))
        let notBound = RecoveryHoldBinding(scope: prepared.scope, hold: token)
        XCTAssertEqual(prepared.admit(utf16Units: 1, binding: notBound) {
            XCTFail("Prearm ещё не связан с очередью"); return true
        }, .rejected(.wrongBinding))
        let bound = try XCTUnwrap(prepared.bindHold(token))
        XCTAssertEqual(bound, notBound)
        XCTAssertEqual(fixture.gate.preparationCount, 1)
        XCTAssertTrue(prepared.permitsMutation(for: bound))
        XCTAssertNil(prepared.bindHold(token))
    }

    @MainActor
    func testReusedPIDOrForeignOperationCannotSatisfyPreparedCapability() throws {
        let fixture = try RecoveryTestFixture()
        let reused = try XCTUnwrap(RecoveryProcessIdentity(processID: 123, birthSeconds: 2, birthMicroseconds: 2))
        let other = ConversionSafetyLedger(generation: 1)
        for scope in [RecoveryOperationTarget(operation: fixture.ledger.operation, target: reused),
                      RecoveryOperationTarget(operation: other.operation, target: fixture.target)] {
            let coordinator = RecoveryCoordinator(gateFactory: RecoveryGateFactory(prepare: { _ in
                fixture.gate.prepare(scope)
            }))
            XCTAssertNil(coordinator.reserve(operation: fixture.ledger.operation, target: fixture.target))
        }
    }

    @MainActor
    func testGateLostBetweenPreparationAndBindingDoesNotPretendReady() throws {
        let fixture = try RecoveryTestFixture()
        let prepared = try XCTUnwrap(fixture.coordinator.reserve(
            operation: fixture.ledger.operation, target: fixture.target
        ))
        fixture.gate.setAvailable(false)
        let buffer = InputEventBuffer()
        let token = try XCTUnwrap(buffer.beginHold(at: 0))
        XCTAssertNil(prepared.bindHold(token))
        XCTAssertTrue(buffer.isHolding)
        fixture.gate.setAvailable(true)
        XCTAssertNil(prepared.bindHold(token), "Поздний возврат gate не возобновляет старый prearm")
        let batch = try XCTUnwrap(buffer.detach(token: token))
        XCTAssertTrue(try XCTUnwrap(batch.claim()).isEmpty)
    }

    @MainActor
    func testEventLimitStopsBeforeTheNextAppendAndPreservesFullPrefix() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        var appended = 0
        for index in 0..<256 {
            let result = hold.admission.admit(utf16Units: 0, binding: hold.binding) { appended += 1; return true }
            XCTAssertEqual(result, index == 255 ? .acceptedRequiringHandover(.eventLimit) : .accepted)
        }
        XCTAssertEqual(hold.admission.admit(utf16Units: 0, binding: hold.binding) {
            appended += 1; return true
        }, .rejected(.eventLimit))
        XCTAssertEqual(appended, 256)
        let sealed = try XCTUnwrap(hold.admission.seal(binding: hold.binding))
        XCTAssertEqual(sealed.counts, RecoveryAdmissionCounts(events: 256, utf16Bytes: 0))
        XCTAssertFalse(hold.admission.permitsMutation(for: hold.binding))
    }

    @MainActor
    func testUTF16BudgetCountsSurrogateUnitsAndRejectsCrossingEventBeforeAppend() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        var appended = 0
        XCTAssertEqual(hold.admission.admit(utf16Units: 32_767, binding: hold.binding) {
            appended += 1; return true
        }, .accepted)
        XCTAssertEqual(hold.admission.admit(utf16Units: "😀".utf16.count, binding: hold.binding) {
            appended += 1; return true
        }, .rejected(.payloadLimit))
        XCTAssertEqual(appended, 1)
        XCTAssertEqual(try XCTUnwrap(hold.admission.seal(binding: hold.binding)).counts,
                       RecoveryAdmissionCounts(events: 1, utf16Bytes: 65_534))
    }

    @MainActor
    func testExactUTF16LimitIsSavedAndFirstOversizedOrInvalidEventIsNot() throws {
        for units in [32_768, 32_769, Int.max, -1] {
            let fixture = try RecoveryTestFixture()
            let hold = try fixture.begin()
            var appended = 0
            let result = hold.admission.admit(utf16Units: units, binding: hold.binding) { appended += 1; return true }
            let expected: RecoveryEventAdmission = units == 32_768
                ? .acceptedRequiringHandover(.payloadLimit) : .rejected(units < 0 ? .invalidCost : .payloadLimit)
            XCTAssertEqual(result, expected)
            XCTAssertEqual(appended, units == 32_768 ? 1 : 0)
            let counts = try XCTUnwrap(hold.admission.seal(binding: hold.binding)).counts
            XCTAssertEqual(counts.events, appended)
            XCTAssertEqual(counts.utf16Bytes, units == 32_768 ? 65_536 : 0)
        }
    }

    @MainActor
    func testAppendFailureDoesNotChargeSavedCount() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        XCTAssertEqual(hold.admission.admit(utf16Units: 5, binding: hold.binding) { false }, .rejected(.appendRejected))
        XCTAssertEqual(try XCTUnwrap(hold.admission.seal(binding: hold.binding)).counts,
                       RecoveryAdmissionCounts(events: 0, utf16Bytes: 0))
    }

    @MainActor
    func testGateLossAfterAppendReportsSavedEventAndDoesNotEraseIt() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        XCTAssertEqual(hold.admission.admit(utf16Units: 2, binding: hold.binding) {
            fixture.gate.setAvailable(false)
            return true
        }, .acceptedRequiringHandover(.gateUnavailable))
        XCTAssertEqual(hold.admission.admit(utf16Units: 1, binding: hold.binding) {
            XCTFail("Новый ввод не должен скрытно расширять префикс"); return true
        }, .rejected(.gateUnavailable))
        let sealed = try XCTUnwrap(hold.admission.seal(binding: hold.binding))
        XCTAssertEqual(sealed.counts, RecoveryAdmissionCounts(events: 1, utf16Bytes: 4))
        XCTAssertTrue(hold.admission.seal(binding: hold.binding) === sealed)
    }

    @MainActor
    func testForeignHoldCannotSpendQuotaOrSealOriginalReservation() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        let foreign = InputEventBuffer()
        let token = try XCTUnwrap(foreign.beginHold(at: 0))
        let binding = RecoveryHoldBinding(scope: hold.binding.scope, hold: token)
        XCTAssertEqual(hold.admission.admit(utf16Units: 1, binding: binding) {
            XCTFail("Чужой token не должен вызвать append"); return true
        }, .rejected(.wrongBinding))
        XCTAssertNil(hold.admission.seal(binding: binding))
        XCTAssertTrue(hold.admission.permitsMutation(for: hold.binding))
        XCTAssertEqual(try hold.append(), .accepted)
    }

    @MainActor
    func testObservedGateLossCannotResumeSameReservationAfterRecovery() throws {
        let fixture = try RecoveryTestFixture()
        let hold = try fixture.begin()
        fixture.gate.setAvailable(false)
        XCTAssertFalse(hold.admission.permitsMutation(for: hold.binding))
        fixture.gate.setAvailable(true)
        XCTAssertFalse(hold.admission.permitsMutation(for: hold.binding))
        XCTAssertEqual(hold.admission.admit(utf16Units: 1, binding: hold.binding) {
            XCTFail("Замеченная потеря gate запрещает возобновление старой reservation"); return true
        }, .rejected(.gateUnavailable))
        XCTAssertEqual(try XCTUnwrap(hold.admission.seal(binding: hold.binding)).counts,
                       RecoveryAdmissionCounts(events: 0, utf16Bytes: 0))
    }
}
