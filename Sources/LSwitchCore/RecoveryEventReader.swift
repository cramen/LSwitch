import CoreGraphics
import Foundation

/// Тесты могут только уменьшить production пределы. Это лимит логического payload, не RSS.
struct RecoveryProjectionLimits {
    let maximumEvents: Int
    let maximumUTF16Units: Int

    init(
        maximumEvents: Int = PreparedRecoveryAdmission.maximumEvents,
        maximumUTF16Units: Int = PreparedRecoveryAdmission.maximumUTF16Bytes / 2
    ) {
        self.maximumEvents = max(0, min(maximumEvents, PreparedRecoveryAdmission.maximumEvents))
        self.maximumUTF16Units = max(0, min(maximumUTF16Units, PreparedRecoveryAdmission.maximumUTF16Bytes / 2))
    }
}

/// Вызывается coordinator только после принятого reveal intent. Не отдаёт CGEvent наружу.
/// Observer видит лишь факт вызова: без event, текста, ordinal или callback доступа к payload.
struct RecoveryEventReader {
    // IOKit/hidsystem/IOLLEvent.h: NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK.
    private static let deviceControl = CGEventFlags(rawValue: 0x0000_2001)
    // NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK, даже без общего NX_COMMANDMASK.
    private static let deviceCommand = CGEventFlags(rawValue: 0x0000_0018)
    // NX_DEVICELALTKEYMASK | NX_DEVICERALTKEYMASK, даже без общего NX_ALTERNATEMASK.
    private static let deviceOption = CGEventFlags(rawValue: 0x0000_0060)
    // NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK: сторону Shift не превращаем в текст.
    private static let deviceShift = CGEventFlags(rawValue: 0x0000_0006)
    // NX_ALPHASHIFT_STATELESS_MASK | NX_DEVICE_ALPHASHIFT_STATELESS_MASK: Caps в keyboard event.
    private static let statelessCaps = CGEventFlags(rawValue: 0x0100_0080)
    private static let mouseEvents: [CGEventType: RecoveryNonTextEvent] = [
        .leftMouseDown: .mouse(button: .left, phase: .down),
        .leftMouseUp: .mouse(button: .left, phase: .up),
        .leftMouseDragged: .mouse(button: .left, phase: .drag),
        .rightMouseDown: .mouse(button: .right, phase: .down),
        .rightMouseUp: .mouse(button: .right, phase: .up),
        .rightMouseDragged: .mouse(button: .right, phase: .drag),
        .otherMouseDown: .mouse(button: .other, phase: .down),
        .otherMouseUp: .mouse(button: .other, phase: .up),
        .otherMouseDragged: .mouse(button: .other, phase: .drag)
    ]
    private let onRead: (() -> Void)?
    private let limits: RecoveryProjectionLimits

    init(onRead: (() -> Void)? = nil, limits: RecoveryProjectionLimits = .init()) {
        self.onRead = onRead
        self.limits = limits
    }

    func project(events: [CGEvent], recordIdentifier: UUID) -> RecoveryProjection {
        onRead?()
        guard events.count <= limits.maximumEvents else {
            return RecoveryProjection(recordIdentifier: recordIdentifier, entries: [], failure: .eventLimitExceeded)
        }
        var entries: [RecoveryProjectionEntry] = []
        entries.reserveCapacity(events.count)
        var remainingUnits = limits.maximumUTF16Units
        for (ordinal, event) in events.enumerated() {
            let content: RecoveryProjectionContent
            if let nonText = classifyWithoutUnicode(event) {
                content = nonText
            } else {
                switch readUnicode(event, remainingUnits: remainingUnits) {
                case .content(let value, let consumed):
                    content = value
                    remainingUnits -= consumed
                case .limitExceeded:
                    return RecoveryProjection(
                        recordIdentifier: recordIdentifier, entries: [], failure: .payloadLimitExceeded
                    )
                }
            }
            entries.append(RecoveryProjectionEntry(ordinal: ordinal, content: content))
        }
        return RecoveryProjection(recordIdentifier: recordIdentifier, entries: entries, failure: nil)
    }

    private enum UnicodeReadResult {
        case content(RecoveryProjectionContent, consumed: Int)
        case limitExceeded
    }

    /// Unicode не читается для Up, modifiers, известных управляющих клавиш и мыши.
    private func classifyWithoutUnicode(_ event: CGEvent) -> RecoveryProjectionContent? {
        if let mouse = Self.mouseEvents[event.type] { return .nonText(mouse) }
        switch event.type {
        case .keyDown: return classifyKeyDown(event)
        case .keyUp: return .nonText(.keyRelease)
        case .flagsChanged: return .nonText(.modifierChange)
        default: return .unresolved(.unsupportedEvent)
        }
    }

    private func classifyKeyDown(_ event: CGEvent) -> RecoveryProjectionContent? {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code >= 0, code <= Int64(UInt16.max) else { return .unresolved(.unsupportedEvent) }
        if let editing = Self.editingKey(code) { return .nonText(.editingKey(editing)) }
        let flags = event.flags
        let commands: CGEventFlags = [.maskCommand, .maskControl]
        if !flags.intersection(commands.union(Self.deviceCommand).union(Self.deviceControl)).isEmpty {
            return .nonText(.modifiedKey)
        }
        let uncertain: CGEventFlags = [.maskAlternate, .maskSecondaryFn]
        if !flags.intersection(uncertain.union(Self.deviceOption)).isEmpty {
            return .unresolved(.modifierDependentInput)
        }
        // CGEventTypes.h: kCGEventFlagMaskNonCoalesced — metadata coalescing мыши/пера, не команда.
        // Остальные low bits не маскируем целиком: неизвестное состояние остаётся неподдержанным.
        let ordinary: CGEventFlags = [.maskShift, .maskAlphaShift, .maskNumericPad, .maskNonCoalesced]
        guard flags.subtracting(ordinary.union(Self.deviceShift).union(Self.statelessCaps)).isEmpty else {
            return .unresolved(.unsupportedModifiers)
        }
        return nil
    }

    private static func editingKey(_ code: Int64) -> RecoveryEditingKey? {
        switch code {
        case 51: return .backspace
        case 117: return .forwardDelete
        case 36, 76: return .enter
        case 48: return .tab
        case 53: return .escape
        case 115, 116, 119, 121, 123...126: return .navigation
        case 64, 79, 80, 90, 96...101, 103, 105...107, 109, 111, 113, 118, 120, 122: return .function
        default: return nil
        }
    }

    private func readUnicode(_ event: CGEvent, remainingUnits: Int) -> UnicodeReadResult {
        var expected = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &expected, unicodeString: nil)
        guard expected >= 0 else { return .content(.unresolved(.unicodeReadInconsistent), consumed: 0) }
        guard expected <= remainingUnits else { return .limitExceeded }
        guard expected > 0 else { return .content(.unresolved(.missingUnicodePayload), consumed: 0) }
        var units = [UniChar](repeating: 0, count: expected)
        var actual = 0
        event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &actual, unicodeString: &units)
        var rechecked = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &rechecked, unicodeString: nil)
        guard rechecked <= remainingUnits else { return .limitExceeded }
        let content = RecoveryUnicodeProjection.content(
            units: units, expectedCount: expected, actualCount: actual, recheckedCount: rechecked
        )
        return .content(content, consumed: expected)
    }
}
