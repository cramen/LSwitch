import LSwitchCore
import ServiceManagement
import SwiftUI

/// Окно настроек MVP (spec settings). Открывается из menu bar.
struct SettingsView: View {

    @ObservedObject var settings: SettingsStore
    let appRules: AppRules

    @State private var newBundleID = ""
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Toggle("LSwitch включён", isOn: $settings.enabled)
            Toggle("Звук при конвертации", isOn: $settings.soundEnabled)
            Stepper(
                "Окно отката: \(Int(settings.undoWindowSeconds)) с",
                value: $settings.undoWindowSeconds,
                in: 1...10,
                step: 1
            )
            Toggle("Запускать при входе", isOn: launchAtLoginBinding)
            if let launchAtLoginError {
                Text(launchAtLoginError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            blockedAppsSection
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 320)
    }

    private var blockedAppsSection: some View {
        Section("Исключения (bundle ID)") {
            ForEach(AppRules.presetBlockedApps.sorted(), id: \.self) { bundleID in
                Label(bundleID, systemImage: "lock")
                    .foregroundStyle(.secondary)
            }
            ForEach(appRules.userBlockedApps, id: \.self) { bundleID in
                HStack {
                    Text(bundleID)
                    Spacer()
                    Button("Удалить") {
                        appRules.removeBlockedApp(bundleID)
                        settings.objectWillChange.send()
                    }
                }
            }
            HStack {
                TextField("com.example.app", text: $newBundleID)
                Button("Добавить") {
                    appRules.addBlockedApp(newBundleID)
                    newBundleID = ""
                    settings.objectWillChange.send()
                }
                .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    settings.launchAtLogin = newValue
                    launchAtLoginError = nil
                } catch {
                    // Debug-бандл без подписи: регистрация может не работать —
                    // показываем ошибку, не роняя приложение (design D6).
                    launchAtLoginError = "Автозапуск недоступен: \(error.localizedDescription)"
                }
            }
        )
    }
}
