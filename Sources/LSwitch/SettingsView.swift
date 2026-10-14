import LSwitchCore
import ServiceManagement
import SwiftUI

/// Окно настроек MVP (spec settings). Открывается из menu bar.
struct SettingsView: View {

    @ObservedObject var settings: SettingsStore
    let appRules: AppRules
    let personalDictionary: PersonalDictionary

    @State private var newBundleID = ""
    @State private var newExceptionWord = ""
    @State private var launchAtLoginError: String?
    /// Триггер перерисовки списка исключений (PersonalDictionary — не ObservableObject).
    @State private var dictionaryVersion = 0

    var body: some View {
        Form {
            Toggle("LSwitch включён", isOn: $settings.enabled)
            Toggle("Автопереключение раскладки", isOn: $settings.autoSwitchEnabled)
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
            dictionarySection
            blockedAppsSection
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 460)
    }

    private var dictionarySection: some View {
        Section("Словарь исключений (не конвертировать)") {
            ForEach(personalDictionary.words, id: \.self) { word in
                HStack {
                    Text(word)
                    Spacer()
                    Button("Удалить") {
                        personalDictionary.remove(word)
                        dictionaryVersion += 1
                    }
                }
            }
            HStack {
                TextField("слово", text: $newExceptionWord)
                Button("Добавить") {
                    personalDictionary.add(newExceptionWord)
                    newExceptionWord = ""
                    dictionaryVersion += 1
                }
                .disabled(newExceptionWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .id(dictionaryVersion)
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
