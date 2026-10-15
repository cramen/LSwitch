import CoreGraphics

extension KeyboardEmitter {
    @MainActor
    struct TrackedDelivery {
        let command: ClipboardCommand
        let targetPID: pid_t
        let isValid: @MainActor () -> Bool
        let beforeKeyDown: @MainActor () -> Bool
        let observer: @MainActor (Phase) -> Void
        let hooks: ConversionDispatchHooks
        let delivery: Delivery
    }

    /// Исходный диапазон проверяется один раз; hooks заново проверяют контекст перед каждым Down.
    @MainActor
    static func sendSelection(
        _ command: NativeSelectionCommand, targetPID: pid_t,
        before: @escaping @MainActor () -> Bool, after: @escaping @MainActor () -> Bool,
        hooks: ConversionDispatchHooks? = nil
    ) async -> Bool {
        let mapped: ClipboardCommand
        switch command {
        case .select(let count): mapped = .selectCharacters(count)
        case .collapse: mapped = .collapseSelection
        }
        guard let hooks else {
            return sendBatch(mapped, targetPID: targetPID, isValid: before, afterBatch: after)
        }
        guard before() else { return false }
        // Живой bound guard находится в hooks. Повтор before после своей стрелки проверял бы старую каретку.
        let sent = await send(mapped, targetPID: targetPID, isValid: { true }, hooks: hooks)
        return sent && after()
    }

    /// Ветка без hooks сохраняет прежний алгоритм. Здесь token выдаётся перед каждым post.
    @MainActor
    static func sendTracked(
        events: [CGEvent], configuration: TrackedDelivery
    ) async -> Bool {
        let hooks = configuration.hooks
        let delivery = configuration.delivery
        let targetPID = configuration.targetPID
        var debt: [Int64: ConversionSafetySubmissionToken] = [:]
        defer {
            for event in events where isRelease(event) && debt[keyCode(event)] != nil {
                guard let token = hooks.beforeSend(.balancingRelease) else { continue }
                delivery.post(event, targetPID)
                debt.removeValue(forKey: keyCode(event))
                hooks.didReturn(.init(submission: token, transport: .keyboard, status: nil))
            }
            for token in debt.values { hooks.didLeaveDebt(token) }
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
            if release { debt.removeValue(forKey: keyCode(event)) } else { debt[keyCode(event)] = token }
            hooks.didReturn(.init(submission: token, transport: .keyboard, status: nil))
            observePost(event, release: release, configuration: configuration)
            if configuration.command == .copy || configuration.command == .paste { await delivery.pause() }
        }
        return configuration.isValid()
    }

    @MainActor
    private static func observePost(_ event: CGEvent, release: Bool, configuration: TrackedDelivery) {
        if event.type == .keyDown { configuration.observer(.keyDown) }
        if event.type == .flagsChanged, !release { configuration.observer(.commandDown) }
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
