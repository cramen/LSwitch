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
        let report = AcceptanceEventTapProbe.run()
        let created = report["tapCreated"] as? Bool == true
        let received = report["received"] as? Int ?? 0
        print("tapCreate (keyUp nonce, listenOnly): \(created ? "создан" : "НЕ СОЗДАН")")
        print("доставка собственного nonce: \(received), ожидается ровно 1; keyDown не отправлялся")
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
