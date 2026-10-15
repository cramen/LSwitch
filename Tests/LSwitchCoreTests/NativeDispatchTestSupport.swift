import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class NativeDispatchFixture {
    let ledger = ConversionSafetyLedger(generation: 1)
    let target: RecoveryProcessIdentity
    let scope: RecoveryOperationTarget

    init() throws {
        target = try XCTUnwrap(RecoveryProcessIdentity(processID: 123, birthSeconds: 10, birthMicroseconds: 20))
        scope = RecoveryOperationTarget(operation: ledger.operation, target: target)
    }

    var keyPair: NativeDispatchPairShape {
        .init(down: .init(phase: .keyDown, keyCode: 123, modifierFlags: 1),
              release: .init(phase: .keyUp, keyCode: 123, modifierFlags: 1))
    }

    var modifierPair: NativeDispatchPairShape {
        .init(down: .init(phase: .modifierDown, keyCode: 56, modifierFlags: 1),
              release: .init(phase: .modifierUp, keyCode: 56, modifierFlags: 0))
    }

    func token(_ kind: ConversionSafetySubmissionKind = .selection) throws -> ConversionSafetySubmissionToken {
        try XCTUnwrap(kind.isCleanup
            ? ledger.willSubmitCleanup(kind, operation: ledger.operation)
            : ledger.willSubmit(kind, operation: ledger.operation))
    }

    func registry(markers: NativeDispatchMarkers? = NativeDispatchMarkers.shared) throws -> NativeDispatchRegistry {
        try XCTUnwrap(NativeDispatchRegistry(scope: scope, markers: markers))
    }

    func gate() throws -> RecipientGateState { try XCTUnwrap(RecipientGateState(scope: scope)) }

    func reusedTarget() throws -> RecoveryProcessIdentity {
        try XCTUnwrap(RecoveryProcessIdentity(processID: target.processID, birthSeconds: 11, birthMicroseconds: 20))
    }
}
