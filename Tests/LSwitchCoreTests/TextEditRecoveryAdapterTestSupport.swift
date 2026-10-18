#if DEBUG
import CoreGraphics
import Darwin
import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

final class TextEditMemoryDriver: TextEditRecoveryDriver, @unchecked Sendable {
    let bridge: RecoveryRecipientProbeBridge
    let state: RecipientTapDriverState
    let clock: EventProcessingTestClock
    private let lock = NSLock()
    private var stopCounter = 0
    @MainActor var flush: RecipientOrdinaryFlush?
    @MainActor var wake: CGEvent?
    @MainActor var onWake: () -> Void = {}

    init(bridge: RecoveryRecipientProbeBridge, state: RecipientTapDriverState, clock: EventProcessingTestClock) {
        self.bridge = bridge
        self.state = state
        self.clock = clock
    }

    var stops: Int { lock.lock(); defer { lock.unlock() }; return stopCounter }
    var permitsCaptureReservation: Bool { state.canArmProtection || state.permitsMutation }
    var permitsMutation: Bool { state.permitsMutation }
    var isProtectionAvailable: Bool { state.isProtectionAvailable }
    func start() async -> Bool { state.workerReady }
    func stop() async -> Bool { recordStop(); state.recordCleanup(); return true }
    func withProtection(_ body: () -> Void) { state.withProtection(body) }
    private func recordStop() { lock.lock(); stopCounter += 1; lock.unlock() }
    @MainActor func refreshProtection() -> Bool { isProtectionAvailable }

    @MainActor
    func armRecipientCapture(
        _ capture: RecipientOrdinaryCapture, processingArm: PreparedEventProcessingArm?
    ) async -> Bool {
        guard let activation = bridge.prepareActivation() else { return false }
        let request = RecipientCaptureArming(state: state, capture: capture, activation: activation,
                                            processingArm: processingArm)
        return await withCheckedContinuation { continuation in request.register(continuation); request.run() }
    }

    @MainActor
    func prepareOrdinaryFlush(
        capture: RecipientOrdinaryCapture, deadline: UInt64, diagnosticMarker: Int64?
    ) -> RecipientOrdinaryFlush? {
        guard let marker = RecipientOrdinaryMarker(sourcePID: getpid(), diagnosticValue: diagnosticMarker) else {
            return nil
        }
        let clock = self.clock
        let flush = RecipientOrdinaryFlush(capture: capture, state: state, marker: marker,
                                          timing: .init(deadline: deadline, now: { clock.read() },
                                                        automaticPolling: false))
        guard state.installOrdinaryFlush(flush) else { return nil }
        self.flush = flush
        return flush
    }

    @MainActor
    func acceptOrdinary(
        _ flush: RecipientOrdinaryFlush, correction: ConversionRecoveryLayoutTransition?,
        claimOwnership: () -> ConversionSafetyInputClaim?
    ) -> ConversionOrdinaryAcceptance {
        flush.accept(correction: correction, claimOwnership: claimOwnership,
                     postWake: { event in self.wake = event; self.onWake(); return true })
    }

    @MainActor
    func deliverWake() throws {
        let wake = try XCTUnwrap(wake)
        XCTAssertFalse(state.observe(type: .keyUp, event: wake, isHead: true, postOrdinary: { _ in }))
    }
}

@MainActor
final class TextEditRecoveryAdapterFixture {
    let ledger: ConversionSafetyLedger
    let clock = EventProcessingTestClock()
    let router = RecoveryCaptureRouter(bypassRawProcessing: true, acceptsRecipientInput: true)
    let processing = EventProcessingLeaseState()
    let driver: TextEditMemoryDriver
    let coordinator: RecoveryCoordinator
    let adapter: TextEditRecoveryAdapter
    let attachment: RecoveryCaptureAttachment

    init(
        ledger: ConversionSafetyLedger? = nil, validationScope: TextEditRecoveryValidationScope? = nil,
        startedAt: UInt64 = 1, currentSafety: @escaping () -> Bool = { true },
        contextIsCurrent: @escaping () -> Bool = { true }
    ) throws {
        let ledger = ledger ?? ConversionSafetyLedger(generation: 1)
        self.ledger = ledger
        clock.advance(to: startedAt)
        let target = try XCTUnwrap(SystemProcessIdentity.read(processID: getpid()))
        let scope = RecoveryOperationTarget(operation: ledger.operation, target: target)
        let gate = try XCTUnwrap(RecipientGateState(scope: scope))
        let bridge = try XCTUnwrap(RecoveryRecipientProbeBridge(
            sender: target, target: target, ledger: ledger, gate: gate))
        let state = RecipientTapDriverState(bridge: bridge)
        state.recordInstallation(head: true, tail: true)
        let driver = TextEditMemoryDriver(bridge: bridge, state: state, clock: clock)
        self.driver = driver
        let coordinator = RecoveryCoordinator(gateFactory: .init(prepare: { scope in
            .init(scope: scope, isCurrent: { driver.permitsCaptureReservation })
        }))
        self.coordinator = coordinator
        let clock = self.clock
        let lease = try XCTUnwrap(processing.begin(scope: scope, at: startedAt))
        let arm = try XCTUnwrap(PreparedEventProcessingArm(state: processing, lease: lease, clock: { clock.read() }))
        let admission = try XCTUnwrap(coordinator.reserve(operation: ledger.operation, target: target))
        let operation = try XCTUnwrap(RecoveryOperation.prepare(
            ledger: ledger, admission: admission, tapIdentifier: router.identifier, at: arm.startedAt,
            handoverFactory: .init(prepare: { scope, identifier in
                .init(operationScope: scope, tapIdentifier: identifier, protecting: { _, body in
                    driver.withProtection(body)
                })
            })
        ))
        let attachment = RecoveryCaptureAttachment(port: operation.capturePort, policy: .recipientInput,
                                                   ownMarker: { bridge.owns(senderPID: $0, marker: $1) },
                                                   clock: { clock.read() })
        self.attachment = attachment
        XCTAssertTrue(router.attach(attachment))
        let capture = try XCTUnwrap(RecipientOrdinaryCapture(router: router, attachment: attachment, scope: scope))
        let controller = EventProcessingLeaseController(state: processing,
                                                        queue: DispatchQueue(label: "textedit-memory-processing"),
                                                        clock: { clock.read() })
        let logical = TextEditRecoveryLogicalLease(prepared: arm, isCurrent: { arm.isCurrent }, drain: {},
            finish: { disposition, actions in
                await controller.finish(lease, disposition: disposition, actions: actions)
            })
        adapter = TextEditRecoveryAdapter(resources: .init(ledger: ledger, coordinator: coordinator,
            driver: driver, operation: operation, capture: capture, logical: logical),
            contextIsCurrent: contextIsCurrent, currentSafety: currentSafety, changed: {},
            validationScope: validationScope)
    }

    func activate() async {
        XCTAssertTrue(adapter.activateCapture())
        let armed = await adapter.arm()
        XCTAssertTrue(armed)
    }

    func enqueue(_ text: String = "kept") throws {
        let event = try EventProcessingTestFixture.event(text)
        XCTAssertTrue(processing.observe(type: .keyDown, event: event, at: clock.read()))
        XCTAssertFalse(driver.state.observe(type: .keyDown, event: event, isHead: true))
    }

    func commit() throws -> ConversionOrdinaryTransport {
        XCTAssertTrue(adapter.prepareOrdinary())
        _ = ledger.finish(operation: ledger.operation, text: .unchangedByOperation,
                          cleanup: .noOwnedMutation, ordinaryRouteValid: true)
        let accepted = adapter.commitOrdinary(correction: nil, claimOwnership: {
            self.ledger.claimInput(operation: self.ledger.operation)
        })
        guard case .accepted(let handle) = accepted else { throw OrdinaryCustodyFixture.PostFailure.injected }
        return handle
    }
}
#endif
