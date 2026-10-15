import CoreGraphics

extension KeyboardEmitter {
    @MainActor
    struct TrackedDelivery {
        let command: ClipboardCommand
        let targetPID: pid_t
        let isValid: @MainActor () -> Bool
        let beforeKeyDown: @MainActor () -> Bool
        let observer: @MainActor (Phase) -> Void
        let hooks: ClipboardDispatchHooks
        let delivery: Delivery
    }

    /// Ветка без hooks сохраняет прежний алгоритм. Здесь token выдаётся перед каждым post.
    @MainActor
    static func sendTracked(
        events: [CGEvent], configuration: TrackedDelivery
    ) async -> Bool {
        let hooks = configuration.hooks
        let delivery = configuration.delivery
        let targetPID = configuration.targetPID
        var debt = Set<Int64>()
        defer {
            for event in events where isRelease(event) && debt.contains(keyCode(event)) {
                guard let token = hooks.beforeSend(.balancingRelease) else { continue }
                delivery.post(event, targetPID)
                debt.remove(keyCode(event))
                hooks.didReturn(.init(submission: token, transport: .keyboard, status: nil))
            }
        }
        for event in events {
            let release = isRelease(event)
            if !release {
                guard configuration.isValid() else { return false }
                if event.type == .keyDown, !configuration.beforeKeyDown() { return false }
            }
            let kind = submissionKind(event, command: configuration.command)
            guard let token = hooks.beforeSend(kind) else { return false }
            delivery.post(event, targetPID)
            if release { debt.remove(keyCode(event)) } else { debt.insert(keyCode(event)) }
            hooks.didReturn(.init(submission: token, transport: .keyboard, status: nil))
            if event.type == .keyDown { configuration.observer(.keyDown) }
            if event.type == .flagsChanged, !release { configuration.observer(.commandDown) }
            if configuration.command == .copy || configuration.command == .paste { await delivery.pause() }
        }
        return configuration.isValid()
    }

    private static func submissionKind(
        _ event: CGEvent, command: ClipboardCommand
    ) -> ConversionSafetySubmissionKind {
        if isRelease(event) { return .balancingRelease }
        return event.type == .flagsChanged ? .modifier : command.submissionKind
    }

    private static func keyCode(_ event: CGEvent) -> Int64 {
        event.getIntegerValueField(.keyboardEventKeycode)
    }

    private static func isRelease(_ event: CGEvent) -> Bool {
        guard event.type == .flagsChanged else { return event.type == .keyUp }
        let flag: CGEventFlags
        switch keyCode(event) {
        case 0x37: flag = .maskCommand
        case 0x38: flag = .maskShift
        case 0x3A: flag = .maskAlternate
        default: return false
        }
        return !event.flags.contains(flag)
    }
}
