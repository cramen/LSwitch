import CoreGraphics
import Dispatch
import Foundation

extension EventTapCore {
    /// Тот же cached mask передаётся настоящему tapCreate; scroll вне lease игнорирует legacy decoder/hold.
    static let subscribedEventMask: CGEventMask = {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    }()

    /// Публикует logical pause до barrier; native доставка не меняется.
    @MainActor
    func beginProcessingLease(scope: RecoveryOperationTarget) async -> EventProcessingLease? {
        guard state == .running, !hasLegacyInputHold, !recoveryCaptureRouter.bypassRawProcessing,
              let lease = await processingLeases.begin(scope: scope) else { return nil }
        guard state == .running else {
            _ = await processingLeases.finish(lease, disposition: .discard,
                                              actions: .init(applyOutcome: {}, reset: {}, consume: { _ in }))
            return nil
        }
        return lease
    }

    @MainActor
    func preCaptureReady(_ lease: EventProcessingLease) -> Bool {
        state == .running && processingLeases.preCaptureReady(lease)
    }

    #if DEBUG
    @MainActor
    func prepareProcessingArm(_ lease: EventProcessingLease) -> PreparedEventProcessingArm? {
        guard state == .running, !hasLegacyInputHold, !recoveryCaptureRouter.bypassRawProcessing else { return nil }
        return processingLeases.prepareRecipientArm(lease)
    }
    #endif

    @MainActor
    func armProcessingLease(_ lease: EventProcessingLease, activate: () -> Bool) -> Bool {
        guard state == .running else { return false }
        return processingLeases.arm(lease, activate: activate)
    }

    @MainActor
    func processingLeaseIsCurrent(_ lease: EventProcessingLease) -> Bool {
        state == .running && processingLeases.state.isCurrent(lease, at: DispatchTime.now().uptimeNanoseconds)
    }

    @MainActor
    func invalidateProcessingLease(_ reason: EventProcessingInvalidation) {
        processingLeases.state.invalidate(reason)
    }

    @MainActor
    func finishProcessingLease(
        _ lease: EventProcessingLease, disposition: EventProcessingDisposition, actions: EventProcessingActions
    ) async -> EventProcessingFinish {
        await processingLeases.finish(lease, disposition: disposition, actions: actions)
    }

    /// После hold пропускает захваченные ранее raw-события через обе очереди потребителя.
    @MainActor
    public func drainPendingEvents() async {
        await withCheckedContinuation { continuation in
            processingQueue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    /// Проверяется потребителем на main непосредственно перед обработкой, а не до async-перехода.
    @MainActor
    public func acceptsForProcessing(_ event: RawKeyEvent) -> Bool { deliveryGate.accepts(timestamp: event.timestamp) }
}
