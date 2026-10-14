import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import LSwitchCore
import SwiftUI

@MainActor
private final class PermissionNoticeModel: ObservableObject {
    @Published var status = PermGuard.Status(accessibility: true, inputMonitoring: true)
    @Published var navigationError: String?
}

/// Немодальное уведомление; повторный одинаковый опрос не открывает закрытое окно.
@MainActor
final class PermissionNoticeController {
    private let model = PermissionNoticeModel()
    private var window: NSWindow?
    private var lastPresented: PermGuard.Status?

    func update(_ status: PermGuard.Status) {
        model.status = status
        if status.allGranted {
            window?.close()
            lastPresented = nil
        }
    }

    func show(_ status: PermGuard.Status, force: Bool = false) {
        model.status = status
        guard force || (!status.allGranted && lastPresented != status) else { return }
        lastPresented = status
        if window == nil { makeWindow() }
        window?.orderFrontRegardless()
    }

    private func makeWindow() {
        let content = PermissionNoticeView(model: model, open: { [weak self] accessibility in
            self?.openSystemSettings(accessibility: accessibility)
        }, close: { [weak self] in self?.window?.close() })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 260),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Доступ LSwitch"
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }

    private func openSystemSettings(accessibility: Bool) {
        if accessibility && !model.status.accessibility {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        } else if !accessibility && !model.status.inputMonitoring {
            _ = CGRequestListenEventAccess()
        }
        let pane = accessibility ? "Privacy_Accessibility" : "Privacy_ListenEvent"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"),
              NSWorkspace.shared.open(url) else {
            model.navigationError = "Откройте «Системные настройки → Конфиденциальность и безопасность» вручную."
            return
        }
        model.navigationError = nil
    }
}

@MainActor
private struct PermissionNoticeView: View {
    @ObservedObject var model: PermissionNoticeModel
    let open: (Bool) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.status.allGranted ? "Разрешения предоставлены" : "LSwitch нужен доступ к вводу")
                .font(.headline)
            Text(model.status.allGranted
                 ? "Оба разрешения доступны. Включением обработки можно управлять в настройках LSwitch."
                 : "Преобразование приостановлено до восстановления доступа. Выберите недостающее разрешение.")
            permissionRow("Универсальный доступ", granted: model.status.accessibility, accessibility: true)
            permissionRow("Мониторинг ввода", granted: model.status.inputMonitoring, accessibility: false)
            if let error = model.navigationError { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button(model.status.allGranted ? "Закрыть" : "Позже", action: close)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    private func permissionRow(_ title: String, granted: Bool, accessibility: Bool) -> some View {
        HStack {
            Text("\(granted ? "✓" : "✗") \(title)")
            Spacer()
            Button("Открыть настройки") { open(accessibility) }
                .accessibilityLabel("Открыть настройки: \(title)")
        }
    }
}
