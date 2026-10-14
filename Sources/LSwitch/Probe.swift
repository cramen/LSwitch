import ApplicationServices
import CoreGraphics
import Foundation

/// Диагностический прогон спайка: `lswitch --probe`.
///
/// Печатает состояние окружения (sandbox, разрешения TCC, доступность
/// event tap и AX) и завершает процесс. Используется для эксперимента
/// P0.4/5.1: сравнение обычной и sandbox-сборки одного бинарника.
enum Probe {

    static func run() -> Never {
        print("== LSwitch probe ==")
        print("sandbox: \(isSandboxed() ? "да" : "нет")")
        print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
        print("CGPreflightListenEventAccess: \(CGPreflightListenEventAccess())")

        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        print("tapCreate (keyboard, listenOnly): \(tap != nil ? "создан" : "НЕ СОЗДАН (nil)")")

        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let axResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        print("AX чтение focused element: \(axResult == .success ? "ок" : "ошибка \(axResult.rawValue)")")
        exit(0)
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
