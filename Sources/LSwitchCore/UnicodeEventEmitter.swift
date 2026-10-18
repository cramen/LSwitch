import CoreGraphics
import Dispatch
import Foundation

/// Подготовленный пакет одноразовый; true означает отправку Down, а не изменение текста.
@MainActor
struct UnicodePreparedPacket {
    var post: (@escaping @MainActor () -> Bool) -> Bool
    var postTracked: ((@escaping @MainActor () -> Bool, ConversionDispatchHooks) -> Bool)?

    init(post: @escaping (@escaping @MainActor () -> Bool) -> Bool) {
        self.post = post
    }

    init(
        post: @escaping (@escaping @MainActor () -> Bool) -> Bool,
        postTracked: @escaping (@escaping @MainActor () -> Bool, ConversionDispatchHooks) -> Bool
    ) {
        self.post = post
        self.postTracked = postTracked
    }
}

@MainActor
enum UnicodeEventEmitter {
    struct Events {
        let down: CGEvent
        let release: CGEvent
    }

    static func prepare(_ text: String, targetPID: pid_t) -> UnicodePreparedPacket? {
        prepare(text, targetPID: targetPID, delivery: { event, processID in
            event.timestamp = DispatchTime.now().uptimeNanoseconds
            event.postToPid(processID)
        })
    }

    static func prepare(
        _ text: String, targetPID: pid_t, delivery: @escaping (CGEvent, pid_t) -> Void
    ) -> UnicodePreparedPacket? {
        guard targetPID > 0, let events = events(for: text) else { return nil }
        var consumed = false
        return UnicodePreparedPacket(post: { isValid in
            guard !consumed, isValid() else { return false }
            consumed = true
            delivery(events.down, targetPID)
            // Отпускаем уже отправленную клавишу тому же PID даже при смене фокуса.
            // Между Down/Up нет await и второго разрешения на текстовую запись.
            delivery(events.release, targetPID)
            return true
        }, postTracked: { isValid, hooks in
            guard !consumed, isValid() else { return false }
            consumed = true
            if let binding = hooks.nativeBinding {
                return sendNative(events, targetPID: targetPID, isValid: isValid, hooks: hooks, binding: binding)
            }
            guard let down = hooks.beforeSend(.text) else { return false }
            delivery(events.down, targetPID)
            hooks.didReturn(.init(submission: down, transport: .unicode, status: nil))
            if let release = hooks.beforeSend(.balancingRelease) {
                delivery(events.release, targetPID)
                hooks.didReturn(.init(submission: release, transport: .unicode, status: nil))
            } else {
                hooks.didLeaveDebt(down)
            }
            return true
        })
    }

    private static func sendNative(
        _ events: Events, targetPID: pid_t, isValid: () -> Bool,
        hooks original: ConversionDispatchHooks, binding: NativeDispatchBinding
    ) -> Bool {
        guard isValid(), let batch = binding.prepare(events: [events.down, events.release]),
              batch.scope.target.processID == targetPID, batch.packets.count == 2 else { return false }
        var hooks = original
        var downToken: ConversionSafetySubmissionToken?
        hooks.beforeSend = { kind in
            let token = original.beforeSend(kind)
            if kind == .text { downToken = token }
            return token
        }
        guard binding.send(batch.packets[0], kind: .text, hooks: hooks, transport: .unicode) else { return false }
        if !binding.send(batch.packets[1], kind: .balancingRelease, hooks: hooks, transport: .unicode),
           let downToken { original.didLeaveDebt(downToken) }
        // Как и прежний контракт: true означает отправку Down, а не completion или отсутствие debt.
        return true
    }

    static func events(for text: String) -> Events? {
        guard UnicodePacketPolicy.permits(text) else { return nil }
        let units = Array(text.utf16)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = makeEvent(units: units, source: source, keyDown: true),
              let release = makeEvent(units: units, source: source, keyDown: false) else { return nil }
        return Events(down: down, release: release)
    }

    static func validates(_ event: CGEvent, units: [UInt16], keyDown: Bool) -> Bool {
        guard event.type == (keyDown ? .keyDown : .keyUp), event.flags.isEmpty,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              event.getIntegerValueField(.keyboardEventKeycode) == 0,
              SyntheticEventMarker.isSynthetic(event) else { return false }
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &count, unicodeString: nil)
        guard count == units.count else { return false }
        var copied = [UniChar](repeating: 0, count: units.count)
        event.keyboardGetUnicodeString(
            maxStringLength: copied.count, actualStringLength: &count, unicodeString: &copied
        )
        return count == units.count && copied == units
    }

    private static func makeEvent(units: [UInt16], source: CGEventSource?, keyDown: Bool) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { return nil }
        event.flags = []
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        guard SyntheticEventMarker.tag(event), validates(event, units: units, keyDown: keyDown) else { return nil }
        return event
    }
}
