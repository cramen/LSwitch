import CoreGraphics

extension KeyboardEmitter {
    /// Bound путь не использует legacy post. Незакрытый баланс остаётся debt, без повтора batch.
    @MainActor
    static func sendNative(configuration: TrackedDelivery, binding: NativeDispatchBinding) async -> Bool {
        guard let batch = binding.prepare(command: configuration.command),
              batch.scope.target.processID == configuration.targetPID else { return false }
        return await NativeDeliveryState(configuration: configuration, binding: binding, batch: batch).run()
    }
}

@MainActor
private final class NativeDeliveryState {
    let configuration: KeyboardEmitter.TrackedDelivery
    let binding: NativeDispatchBinding
    let batch: NativePreparedBatch
    private var debt: [Int: ConversionSafetySubmissionToken] = [:]
    private var attempted = Set<Int>()
    private var lastToken: ConversionSafetySubmissionToken?

    init(configuration: KeyboardEmitter.TrackedDelivery, binding: NativeDispatchBinding, batch: NativePreparedBatch) {
        self.configuration = configuration
        self.binding = binding
        self.batch = batch
    }

    private var hooks: ConversionDispatchHooks {
        var hooks = configuration.hooks
        hooks.beforeSend = { kind in
            self.lastToken = self.configuration.hooks.beforeSend(kind)
            return self.lastToken
        }
        return hooks
    }

    func run() async -> Bool {
        var completed = true
        for (index, packet) in batch.packets.enumerated() {
            guard send(packet, index: index) else { completed = false; break }
            if configuration.command == .copy || configuration.command == .paste {
                await configuration.delivery.pause()
            }
        }
        balanceRemaining()
        for token in debt.values { configuration.hooks.didLeaveDebt(token) }
        return completed && debt.isEmpty && configuration.isValid()
    }

    private func send(_ packet: NativePreparedBatch.Packet, index: Int) -> Bool {
        if packet.shape.phase.isDown {
            guard configuration.isValid() else { return false }
            if packet.shape.phase == .keyDown, !configuration.beforeKeyDown() { return false }
        }
        attempted.insert(index)
        guard binding.send(packet, kind: kind(packet.shape), hooks: hooks, transport: .keyboard) else { return false }
        if packet.shape.phase.isDown {
            debt[index] = lastToken
        } else {
            debt.removeValue(forKey: packet.partnerIndex)
        }
        if packet.shape.phase == .keyDown { configuration.observer(.keyDown) }
        if packet.shape.phase == .modifierDown { configuration.observer(.commandDown) }
        return true
    }

    private func balanceRemaining() {
        for (index, packet) in batch.packets.enumerated() where !packet.shape.phase.isDown {
            guard debt[packet.partnerIndex] != nil, !attempted.contains(index) else { continue }
            if binding.send(packet, kind: .balancingRelease, hooks: hooks, transport: .keyboard) {
                debt.removeValue(forKey: packet.partnerIndex)
            }
        }
    }

    private func kind(_ shape: NativeDispatchShape) -> ConversionSafetySubmissionKind {
        switch shape.phase {
        case .keyDown: return configuration.command.submissionKind
        case .modifierDown: return .modifier
        case .keyUp, .modifierUp: return .balancingRelease
        }
    }
}
