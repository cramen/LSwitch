import ApplicationServices
import CoreGraphics
import Foundation
import LSwitchCore

/// Диагностический прогон спайка: `lswitch --probe`.
///
/// Печатает состояние окружения (sandbox, разрешения TCC, доступность
/// event tap и AX) и завершает процесс. Используется для эксперимента
/// P0.4/5.1: сравнение обычной и sandbox-сборки одного бинарника.
enum Probe {

    private final class Counter {
        var received = 0
    }

    static func run() -> Never {
        print("== LSwitch probe ==")
        print("sandbox: \(isSandboxed() ? "да" : "нет")")
        print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
        print("CGPreflightListenEventAccess: \(CGPreflightListenEventAccess())")
        checkEventTap()
        checkAccessibility()
        checkLayoutManager()
        exit(0)
    }

    private static func checkEventTap() {
        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let counter = Counter()
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, _, event, userInfo in
                if let userInfo {
                    let counter = Unmanaged<Counter>.fromOpaque(userInfo).takeUnretainedValue()
                    counter.received += 1
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(counter).toOpaque()
        )
        print("tapCreate (keyboard, listenOnly): \(tap != nil ? "создан" : "НЕ СОЗДАН (nil)")")
        guard let tap else { return }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true) else {
            print("не удалось создать тестовое событие")
            return
        }
        event.post(tap: .cghidEventTap)
        // Крутим runloop до 2 секунд, ожидая доставку события в tap.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && counter.received == 0 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        print("доставка событий в tap: \(counter.received > 0 ? "РАБОТАЕТ" : "МОЛЧИТ (нет событий за 2 с)")")
    }

    private static func checkAccessibility() {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let axResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        print("AX чтение focused element: \(axResult == .success ? "ок" : "ошибка \(axResult.rawValue)")")
    }

    /// Проверка LayoutManager: чтение, круговое переключение и возврат.
    private static func checkLayoutManager() {
        let layoutManager = LayoutManager()
        print("TIS источники: \(layoutManager.enabledSourceIDs())")
        guard let before = layoutManager.currentLayout() else {
            print("текущая раскладка: неизвестна (\(layoutManager.currentSourceID() ?? "?"))")
            return
        }
        print("текущая раскладка: \(before.rawValue)")
        let target = before.opposite
        let switched = layoutManager.switchTo(target)
        let afterSwitch = layoutManager.currentLayout()
        let restored = layoutManager.switchTo(before)
        let switchOK = switched && afterSwitch == target ? "ок" : "НЕУДАЧА"
        print("переключение → \(target.rawValue): \(switchOK), возврат: \(restored ? "ок" : "НЕУДАЧА")")
    }

    /// Процесс в App Sandbox, если entitlement выставлен в подписи.
    private static func isSandboxed() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.app-sandbox" as CFString,
            nil
        )
        return (value as? Bool) ?? false
    }
}
