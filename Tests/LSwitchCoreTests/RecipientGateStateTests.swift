import Foundation
@testable import LSwitchCore
import XCTest

final class RecipientGateStateTests: XCTestCase {
    @MainActor
    func testProtectionMustBeActivatedForExactScopeBeforeSubmission() throws {
        let fixture = try NativeDispatchFixture()
        let gate = try fixture.gate()
        let pair = try XCTUnwrap(gate.reservePairs([fixture.keyPair], scope: fixture.scope)?.first)
        let down = try fixture.token()
        XCTAssertFalse(gate.snapshot.permitsMutation)
        XCTAssertFalse(gate.registerSubmitted(pair.down, token: down, scope: fixture.scope))
        let foreign = try NativeDispatchFixture()
        XCTAssertFalse(gate.activateProtection(scope: foreign.scope))
        XCTAssertTrue(gate.activateProtection(scope: fixture.scope))
        XCTAssertFalse(gate.activateProtection(scope: fixture.scope))
        XCTAssertTrue(gate.snapshot.permitsMutation)
        XCTAssertTrue(gate.registerSubmitted(pair.down, token: down, scope: fixture.scope))
    }

    @MainActor
    func testUnmatchedTargetDownBlocksSynchronouslyAndRequestsHandover() throws {
        let fixture = try NativeDispatchFixture()
        let gate = try fixture.gate()
        XCTAssertEqual(gate.observeUnmatchedTargetDown(target: fixture.target).route, .allow)
        XCTAssertTrue(gate.activateProtection(scope: fixture.scope))
        let result = gate.observeUnmatchedTargetDown(target: fixture.target)
        XCTAssertEqual(result.route, .block)
        XCTAssertTrue(result.handoverRequested)
        XCTAssertTrue(result.protectionAvailable)
        XCTAssertNil(result.admission, "Новый пользовательский Down не изображается собственной отправкой")
        XCTAssertEqual(gate.snapshot.phase, .quarantined)
        XCTAssertFalse(gate.snapshot.permitsMutation)
        XCTAssertEqual(gate.snapshot.entryCount, 0)
        XCTAssertEqual(fixture.ledger.submissionCount, 0)
    }

    @MainActor
    func testForeignProcessAndReusedPIDAreNotQuarantinedAsTheOriginalRecipient() throws {
        let fixture = try NativeDispatchFixture()
        let gate = try fixture.gate()
        XCTAssertTrue(gate.activateProtection(scope: fixture.scope))
        let different = try XCTUnwrap(RecoveryProcessIdentity(processID: 456, birthSeconds: 10, birthMicroseconds: 20))
        for target in [different, try fixture.reusedTarget()] {
            let result = gate.observeUnmatchedTargetDown(target: target)
            XCTAssertEqual(result.route, .allow)
            XCTAssertFalse(result.handoverRequested)
        }
        XCTAssertTrue(gate.snapshot.permitsMutation)
    }

    @MainActor
    func testQuarantineAllowsOnlyPairedReleaseOfPreviouslyAdmittedDown() throws {
        let fixture = try NativeDispatchFixture()
        let gate = try fixture.gate()
        let pairs = try XCTUnwrap(gate.reservePairs([fixture.modifierPair, fixture.keyPair], scope: fixture.scope))
        let pair = try XCTUnwrap(pairs.first)
        let later = try XCTUnwrap(pairs.last)
        XCTAssertTrue(gate.activateProtection(scope: fixture.scope))
        let down = try fixture.token(.modifier)
        XCTAssertTrue(gate.registerSubmitted(pair.down, token: down, scope: fixture.scope))
        let accepted = gate.observeOwned(marker: pair.down.marker, shape: fixture.modifierPair.down,
                                        target: fixture.target)
        XCTAssertEqual(accepted.admission, .admitted(down))
        XCTAssertEqual(accepted.route, .allow)
        XCTAssertEqual(gate.observeUnmatchedTargetDown(target: fixture.target).route, .block)
        XCTAssertFalse(gate.registerSubmitted(later.down, token: try fixture.token(), scope: fixture.scope))
        let release = try fixture.token(.balancingRelease)
        XCTAssertTrue(gate.registerSubmitted(pair.release, token: release, scope: fixture.scope))
        let balanced = gate.observeOwned(marker: pair.release.marker, shape: fixture.modifierPair.release,
                                        target: fixture.target)
        XCTAssertEqual(balanced.admission, .admitted(release))
        XCTAssertEqual(balanced.route, .allow)
        XCTAssertTrue(balanced.handoverRequested, "Парный Up не отменяет handover")
        XCTAssertFalse(gate.snapshot.permitsMutation)
    }

    @MainActor
    func testCloseBeforeAdmissionDoesNotInventCompletionOrPrevention() throws {
        let fixture = try NativeDispatchFixture()
        let gate = try fixture.gate()
        let pair = try XCTUnwrap(gate.reservePairs([fixture.keyPair], scope: fixture.scope)?.first)
        XCTAssertTrue(gate.activateProtection(scope: fixture.scope))
        let down = try fixture.token()
        XCTAssertTrue(gate.registerSubmitted(pair.down, token: down, scope: fixture.scope))
        gate.closeGeneration()
        XCTAssertEqual(gate.snapshot.phase, .closed)
        XCTAssertEqual(gate.status(of: pair.down), .submitted(down))
        XCTAssertTrue(fixture.ledger.hasUnresolvedSubmissions)
        let rejected = gate.observeOwned(marker: pair.down.marker, shape: fixture.keyPair.down, target: fixture.target)
        XCTAssertEqual(rejected.route, .block)
        XCTAssertEqual(rejected.admission, .prevented(down, .generationClosed))
        XCTAssertTrue(fixture.ledger.hasUnresolvedSubmissions, "Решение callback ещё не является вызовом ledger")
    }

    @MainActor
    func testAdmissionDoesNotProvideReceiverCompletionEvenAfterGenerationClosure() throws {
        let fixture = try NativeDispatchFixture()
        let gate = try fixture.gate()
        let pair = try XCTUnwrap(gate.reservePairs([fixture.keyPair], scope: fixture.scope)?.first)
        XCTAssertTrue(gate.activateProtection(scope: fixture.scope))
        let down = try fixture.token()
        XCTAssertTrue(gate.registerSubmitted(pair.down, token: down, scope: fixture.scope))
        let result = gate.observeOwned(marker: pair.down.marker, shape: fixture.keyPair.down, target: fixture.target)
        XCTAssertEqual(result.admission, .admitted(down))
        XCTAssertTrue(fixture.ledger.observe(.admitted, for: down))
        gate.closeGeneration()
        XCTAssertEqual(gate.status(of: pair.down), .admitted(down))
        XCTAssertTrue(fixture.ledger.hasUnresolvedSubmissions)
        let final = try XCTUnwrap(fixture.ledger.finish(
            operation: fixture.ledger.operation, text: .unknown,
            cleanup: .recoveredObserved, ordinaryRouteValid: true
        ))
        XCTAssertEqual(final.input, .recoveryRequired)
    }

    @MainActor
    func testLostLatchCannotBeRevivedByActivateCloseOrLateOwnCallback() throws {
        let fixture = try NativeDispatchFixture()
        let gate = try fixture.gate()
        let pair = try XCTUnwrap(gate.reservePairs([fixture.keyPair], scope: fixture.scope)?.first)
        XCTAssertTrue(gate.activateProtection(scope: fixture.scope))
        let down = try fixture.token()
        XCTAssertTrue(gate.registerSubmitted(pair.down, token: down, scope: fixture.scope))
        gate.markLost()
        XCTAssertEqual(gate.status(of: pair.down), .submitted(down))
        XCTAssertFalse(gate.activateProtection(scope: fixture.scope))
        gate.closeGeneration()
        XCTAssertEqual(gate.snapshot.phase, .lost)
        XCTAssertNil(gate.reservePairs([fixture.keyPair], scope: fixture.scope))
        let result = gate.observeOwned(marker: pair.down.marker, shape: fixture.keyPair.down, target: fixture.target)
        XCTAssertEqual(result.route, .block)
        XCTAssertEqual(result.admission, .prevented(down, .gateLost))
        XCTAssertFalse(result.protectionAvailable, "Чистое решение не обещает работу отключённого системного tap")
        XCTAssertTrue(result.handoverRequested)
        XCTAssertEqual(gate.snapshot.phase, .lost)
    }

    @MainActor
    func testUnknownMarkerDoesNotPassAsSyntheticAndMatchingSlotRemainsUnresolved() throws {
        let fixture = try NativeDispatchFixture()
        let gate = try fixture.gate()
        let pair = try XCTUnwrap(gate.reservePairs([fixture.keyPair], scope: fixture.scope)?.first)
        XCTAssertTrue(gate.ownsReservedMarker(pair.down.marker, target: fixture.target))
        XCTAssertFalse(gate.ownsReservedMarker(0, target: fixture.target))
        XCTAssertTrue(gate.activateProtection(scope: fixture.scope))
        let down = try fixture.token()
        XCTAssertTrue(gate.registerSubmitted(pair.down, token: down, scope: fixture.scope))
        let result = gate.observeOwned(marker: 0, shape: fixture.keyPair.down, target: fixture.target)
        XCTAssertEqual(result.admission, .rejected(.unknownMarker))
        XCTAssertEqual(result.route, .block)
        XCTAssertTrue(result.handoverRequested)
        XCTAssertEqual(gate.status(of: pair.down), .submitted(down))
    }
}
