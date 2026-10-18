import AppKit
import LSwitchCore

/// Состояние menu bar без захвата фокуса после частично выполненной операции.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    var onToggle: () -> Void = {}
    var onSettings: () -> Void = {}
    var onPermissions: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onRecovery: () -> Void = {}

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let toggle = NSMenuItem(title: "", action: nil, keyEquivalent: "e")
    private let permissions = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let warning = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let recovery = NSMenuItem(title: "Восстановить сохранённый ввод…", action: nil, keyEquivalent: "")
    private var enabled = true
    private var status = PermGuard.Status(accessibility: true, inputMonitoring: true)
    private var operationWarning: String?

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        toggle.target = self
        toggle.action = #selector(toggleAction)
        menu.addItem(toggle)
        permissions.target = self
        permissions.action = #selector(permissionsAction)
        menu.addItem(permissions)
        warning.isEnabled = false
        warning.isHidden = true
        menu.addItem(warning)
        recovery.target = self
        recovery.action = #selector(recoveryAction)
        recovery.isHidden = true
        menu.addItem(recovery)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Настройки…", action: #selector(settingsAction), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Выйти из LSwitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        ))
        item.menu = menu
        refresh()
    }

    func update(enabled: Bool, status: PermGuard.Status) {
        self.enabled = enabled
        self.status = status
        refresh()
    }

    func showOutcome(_ outcome: Converter.Outcome) {
        switch outcome {
        case .partiallyConverted:
            operationWarning = "Текст изменён — проверьте раскладку"
        case .partiallyUndone:
            operationWarning = "Текст восстановлен — проверьте раскладку"
        case .converted, .undone:
            operationWarning = nil
        default:
            break
        }
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { onRefresh() }

    func setRecoveryAvailable(_ available: Bool) { recovery.isHidden = !available }

    private func refresh() {
        toggle.title = enabled ? "Выключить LSwitch" : "Включить LSwitch"
        let axMark = status.accessibility ? "✓" : "✗"
        let inputMark = status.inputMonitoring ? "✓" : "✗"
        permissions.title = "Разрешения — Доступ: \(axMark), Мониторинг ввода: \(inputMark)"
        warning.title = operationWarning ?? ""
        warning.isHidden = operationWarning == nil
        if !enabled {
            item.button?.title = "L̶S̶"
        } else {
            item.button?.title = status.allGranted && operationWarning == nil ? "LS" : "LS!"
        }
        item.button?.toolTip = status.allGranted ? operationWarning : "LSwitch: необходимы разрешения"
    }

    @objc private func toggleAction() { onToggle() }
    @objc private func settingsAction() { onSettings() }
    @objc private func permissionsAction() { onPermissions() }
    @objc private func recoveryAction() { onRecovery() }
}
