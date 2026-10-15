import ApplicationServices
import Foundation
import os

/// Команда активного приложения вызывается через AX без открытия меню и смены фокуса.
@MainActor
enum MenuCommand {
    enum Outcome: Equatable {
        case performed
        case unavailable
        /// AXPress уже отправлен либо контекст устарел; повторять команду нельзя.
        case failed
    }

    private struct Handles {
        var copy: AXUIElement?
        var paste: AXUIElement?
        var complete: Bool { copy != nil && paste != nil }
    }

    private static let logger = Logger(subsystem: "LSwitch", category: "Keyboard")
    private static var cache: [pid_t: Handles] = [:]

    /// Поиск обеих команд выполняется до выделения текста. Enabled намеренно
    /// не участвует в кэше: Copy/Paste могут включиться после выделения/записи clipboard.
    static func prepare(targetPID: pid_t, isValid: () -> Bool) {
        guard targetPID > 0, isValid() else { return }
        var handles = cache[targetPID] ?? Handles()
        if let item = handles.copy, !isIdentity(.copy, element: item) { handles.copy = nil }
        if let item = handles.paste, !isIdentity(.paste, element: item) { handles.paste = nil }
        if handles.complete { return }
        guard let menu = menuBar(of: AXUIElementCreateApplication(targetPID)) else { return }
        var remaining = 300
        if let edit = children(of: menu).first(where: {
            let title = (attribute(kAXTitleAttribute, element: $0) as? String)?.lowercased()
            return title == "edit" || title == "правка"
        }) {
            handles = find(in: edit, depth: 1, handles: handles, remaining: &remaining, isValid: isValid)
        }
        if !handles.complete {
            handles = find(in: menu, depth: 0, handles: handles, remaining: &remaining, isValid: isValid)
        }
        if isValid() { cache[targetPID] = handles }
    }

    static func invoke(
        _ command: ClipboardCommand,
        targetPID: pid_t,
        isValid: () -> Bool
    ) -> Outcome {
        guard command == .copy || command == .paste else { return .unavailable }
        guard targetPID > 0, isValid() else { return .failed }
        guard let item = enabledItem(command, targetPID: targetPID) else { return .unavailable }
        return press(item, command: command, isValid: isValid)
    }

    /// Paste разрешён после устойчивого AX-выделения и повторной проверки меню/контекста.
    static func pasteAfterSelection(
        targetPID: pid_t,
        select: () async -> Bool,
        afterSelectionCheck: () -> Bool,
        isValid: () -> Bool
    ) async -> Outcome {
        guard targetPID > 0, isValid() else {
            logger.notice("transport=menu stage=prepare context=false")
            return .failed
        }
        guard let item = enabledItem(.paste, targetPID: targetPID) else {
            logger.notice("transport=menu stage=prepare available=false")
            return .unavailable
        }
        let selected = await select()
        let confirmed = afterSelectionCheck()
        guard selected else {
            logger.notice("transport=menu stage=select applied=false check=\(confirmed, privacy: .public)")
            return .failed
        }
        guard confirmed else {
            logger.notice("transport=menu stage=check confirmed=false")
            return .failed
        }
        guard isValid() else {
            logger.notice("transport=menu stage=check context=false")
            return .failed
        }
        guard let current = enabledItem(.paste, targetPID: targetPID), CFEqual(current, item),
              isValid(), afterSelectionCheck() else { return .failed }
        return press(item, command: .paste, isValid: isValid)
    }

    private static func enabledItem(_ command: ClipboardCommand, targetPID: pid_t) -> AXUIElement? {
        let item = command == .copy ? cache[targetPID]?.copy : cache[targetPID]?.paste
        guard let item, isIdentity(command, element: item),
              attribute(kAXEnabledAttribute, element: item) as? Bool == true else { return nil }
        return item
    }

    private static func press(_ item: AXUIElement, command: ClipboardCommand, isValid: () -> Bool) -> Outcome {
        guard isValid() else { return .failed }
        SystemAXTextAccess.limitMessaging(item)
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard isValid() else { return .failed }
        // После select AXPress может быть неоднозначным: не повторяем команды.
        guard result == .success else { return .failed }
        let key = command == .copy ? "c" : "v"
        logger.info("transport=menu command=\(key, privacy: .public)")
        return .performed
    }

    static func matches(_ command: ClipboardCommand, character: String?, modifiers: Int?, enabled: Bool) -> Bool {
        guard enabled, modifiers == 0 else { return false }
        // AXMenuItemModifiers: 0 означает только Command; 8 — отсутствие Command.
        // Shift/Option/Control представлены отдельными битами 1/2/4.
        switch command {
        case .copy: return character?.lowercased() == "c"
        case .paste: return character?.lowercased() == "v"
        default: return false
        }
    }

    private static func find(
        in menu: AXUIElement,
        depth: Int,
        handles: Handles,
        remaining: inout Int,
        isValid: () -> Bool
    ) -> Handles {
        var found = handles
        var pending: [(element: AXUIElement, depth: Int)] = [(menu, depth)]
        var index = 0
        while index < pending.count && remaining > 0 && !found.complete {
            guard isValid() else { return found }
            let node = pending[index]
            index += 1
            remaining -= 1
            if found.copy == nil, isIdentity(.copy, element: node.element) { found.copy = node.element }
            if found.paste == nil, isIdentity(.paste, element: node.element) { found.paste = node.element }
            guard node.depth < 4 else { continue }
            for child in children(of: node.element).prefix(max(0, remaining - pending.count + index)) {
                pending.append((child, node.depth + 1))
            }
        }
        return found
    }

    private static func isIdentity(_ command: ClipboardCommand, element: AXUIElement) -> Bool {
        guard attribute(kAXRoleAttribute, element: element) as? String == kAXMenuItemRole else { return false }
        let character = attribute(kAXMenuItemCmdCharAttribute, element: element) as? String
        let modifiers = attribute(kAXMenuItemCmdModifiersAttribute, element: element) as? NSNumber
        return matches(command, character: character, modifiers: modifiers?.intValue, enabled: true)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        Array((attribute(kAXChildrenAttribute, element: element) as? [AXUIElement] ?? []).prefix(300))
    }

    private static func menuBar(of application: AXUIElement) -> AXUIElement? {
        guard let value = attribute(kAXMenuBarAttribute, element: application),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (value as! AXUIElement)
    }

    private static func attribute(_ name: String, element: AXUIElement) -> CFTypeRef? {
        SystemAXTextAccess.limitMessaging(element)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
