#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class OrdinaryCustodyFixture {
    let recovery: RecoveryRetirementFixture
    let claim: ConversionSafetyInputClaim
    let proof: RecoveryRetiredCaptureProof
    let custody: OrdinaryInputCustody

    init(_ texts: [String] = ["a", "b", "c"]) throws {
        let recovery = try RecoveryRetirementFixture()
        self.recovery = recovery
        let port = recovery.operation.capturePort
        for text in texts {
            let event = try RecoveryOperationFixture.event(text)
            XCTAssertEqual(port.capture(event, utf16Units: text.utf16.count, from: port.scope, at: 1), .accepted)
        }
        _ = recovery.ledger.finish(operation: recovery.ledger.operation, text: .unchangedByOperation,
                                   cleanup: .noOwnedMutation, ordinaryRouteValid: true)
        let claim = try XCTUnwrap(recovery.ledger.claimInput(operation: recovery.ledger.operation))
        self.claim = claim
        let proof = try recovery.retiredProof()
        self.proof = proof
        custody = try XCTUnwrap(port.takeOrdinary(claim: claim, quiescence: proof))
    }

    func adopt(_ proof: OrdinaryTerminalProof) throws -> [String] {
        guard case .adopted = recovery.coordinator.adoptRetainedOrdinary(proof: proof) else {
            XCTFail("Ожидается передача полного оригинала с прежним ordinary claim")
            return []
        }
        return try Self.reveal(recovery.coordinator)
    }

    static func reveal(_ coordinator: RecoveryCoordinator) throws -> [String] {
        let intent = try XCTUnwrap(coordinator.requestReveal())
        XCTAssertTrue(coordinator.reveal(intent))
        return try XCTUnwrap(coordinator.revealedProjection).entries.compactMap {
            guard case .unicodeFragment(let fragment) = $0.content else { return nil }
            return fragment.text
        }
    }

    static var policy: OrdinaryDispatchPolicy { .init(deadline: 100, now: { 0 }, canContinue: { true }) }
    enum PostFailure: Error { case injected }

    static func setText(_ text: String, on event: CGEvent) {
        let units = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    }

    static func text(_ event: CGEvent) -> String {
        var units = [UniChar](repeating: 0, count: 64)
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
        return String(decoding: units.prefix(min(length, units.count)), as: UTF16.self)
    }
}
#endif
