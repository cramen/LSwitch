#if DEBUG
import CoreGraphics
import Darwin
import Foundation
@testable import LSwitchCore
import XCTest

final class RecipientOrdinaryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1
    func set(_ next: UInt64) { lock.lock(); value = next; lock.unlock() }
    func read() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
}

/// Настоящие capture/ledger/custody, только native post заменён на память.
@MainActor
final class RecipientOrdinaryFixture {
    let ledger = ConversionSafetyLedger(generation: 1)
    let router = RecoveryCaptureRouter(bypassRawProcessing: true, acceptsRecipientInput: true)
    let clock = RecipientOrdinaryClock()
    let bridge: RecoveryRecipientProbeBridge
    let state: RecipientTapDriverState
    let coordinator: RecoveryCoordinator
    let operation: RecoveryOperation
    let attachment: RecoveryCaptureAttachment
    let capture: RecipientOrdinaryCapture
    let flush: RecipientOrdinaryFlush
    var wake: CGEvent?
    var claims = 0

    init(
        arm: Bool = true, deadline: UInt64 = 100, startedAt: UInt64 = 0,
        observePhase: @escaping @Sendable (RecoveryCapturePhase) -> Void = { _ in }
    ) throws {
        let target = try XCTUnwrap(SystemProcessIdentity.read(processID: getpid()))
        let scope = RecoveryOperationTarget(operation: ledger.operation, target: target)
        let gate = try XCTUnwrap(RecipientGateState(scope: scope))
        let bridge = try XCTUnwrap(RecoveryRecipientProbeBridge(sender: target, target: target,
                                                              ledger: ledger, gate: gate))
        self.bridge = bridge
        let state = RecipientTapDriverState(bridge: bridge)
        self.state = state
        state.recordInstallation(head: true, tail: true)
        let coordinator = RecoveryCoordinator(gateFactory: .init(prepare: { scope in
            .init(scope: scope, isCurrent: { state.workerReady })
        }))
        self.coordinator = coordinator
        let admission = try XCTUnwrap(coordinator.reserve(operation: ledger.operation, target: target))
        let operation = try XCTUnwrap(RecoveryOperation.prepare(
            ledger: ledger, admission: admission, tapIdentifier: router.identifier, at: startedAt,
            handoverFactory: .init(prepare: { scope, identifier in
                .init(operationScope: scope, tapIdentifier: identifier, protecting: { _, body in
                    state.withProtection(body)
                })
            })
        ))
        self.operation = operation
        let clock = self.clock
        let attachment = RecoveryCaptureAttachment(
            port: operation.capturePort, policy: .recipientInput, ownMarker: { _, _ in false },
            clock: { clock.read() }, observePhase: observePhase
        )
        self.attachment = attachment
        XCTAssertTrue(router.attach(attachment))
        let capture = try XCTUnwrap(RecipientOrdinaryCapture(router: router, attachment: attachment, scope: scope))
        self.capture = capture
        if arm {
            let activation = try XCTUnwrap(bridge.prepareActivation())
            XCTAssertTrue(state.publishRecipientCapture(capture, activation: activation))
        }
        let marker = try XCTUnwrap(RecipientOrdinaryMarker(sourcePID: getpid()))
        let timing = RecipientOrdinaryTiming(deadline: deadline, now: { clock.read() }, automaticPolling: false)
        flush = RecipientOrdinaryFlush(capture: capture, state: state, marker: marker, timing: timing)
        XCTAssertTrue(state.installOrdinaryFlush(flush))
    }

    func enqueue(_ text: String = "abc", type: CGEventType = .keyDown) throws {
        let event = try RecoveryOperationFixture.event(text)
        event.type = type
        event.timestamp = 10
        event.setIntegerValueField(.eventSourceUserData, value: 7711)
        XCTAssertFalse(state.observe(type: type, event: event, isHead: true))
    }

    func accept(correction: ConversionRecoveryLayoutTransition? = nil, postsWake: Bool = true) throws {
        _ = ledger.finish(operation: ledger.operation, text: .unchangedByOperation,
                          cleanup: .noOwnedMutation, ordinaryRouteValid: true)
        let result = flush.accept(correction: correction, claimOwnership: {
            self.claims += 1
            return self.ledger.claimInput(operation: self.ledger.operation)
        }, postWake: { event in self.wake = event; return postsWake })
        guard case .accepted = result else { return XCTFail("Ожидается единственный принятый ordinary claim") }
    }

    func deliver(post: ((CGEvent) throws -> Void)? = { _ in }) throws {
        let wake = try XCTUnwrap(wake)
        XCTAssertFalse(state.observe(type: .keyUp, event: wake, isHead: true, postOrdinary: post))
    }

    func retainedText() throws -> [String] {
        let proof = try XCTUnwrap(flush.terminalProof)
        guard case .adopted = coordinator.adoptRetainedOrdinary(proof: proof) else {
            XCTFail("Оригинал должен остаться с тем же ordinary claim")
            return []
        }
        return try OrdinaryCustodyFixture.reveal(coordinator)
    }
}
#endif
