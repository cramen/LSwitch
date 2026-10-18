import AppKit
import Combine
import LSwitchCore
import SwiftUI

/// Окно настроек MVP (spec settings). Открывается из menu bar.
@MainActor
struct SettingsView: View {

    @ObservedObject var settings: SettingsStore
    let hotkeys: HotkeySettingsController
    let appRules: AppRules
    @ObservedObject var personalDictionary: PersonalDictionary

    @State private var newBundleID = ""
    @State private var newExceptionWord = ""
    @StateObject private var launchAtLogin: LaunchAtLoginController

    init(settings: SettingsStore, appRules: AppRules, personalDictionary: PersonalDictionary,
         hotkeys: HotkeySettingsController) {
        self.hotkeys = hotkeys
        self.settings = settings
        self.appRules = appRules
        self.personalDictionary = personalDictionary
        _launchAtLogin = StateObject(wrappedValue: LaunchAtLoginController(settings: settings))
    }

    var body: some View {
        Form {
            Toggle("LSwitch включён", isOn: $settings.enabled)
            Toggle("Автопереключение раскладки", isOn: $settings.autoSwitchEnabled)
            Stepper(
                "Отмен до добавления в исключения: \(settings.undoLearningThreshold)",
                value: $settings.undoLearningThreshold,
                in: AutoSwitchCoordinator.learningThresholdRange
            )
            Toggle("Звук при конвертации", isOn: $settings.soundEnabled)
            Stepper(
                "Окно отката: \(Int(settings.undoWindowSeconds)) с",
                value: $settings.undoWindowSeconds,
                in: 1...10,
                step: 1
            )
            HotkeySettingsView(settings: settings, controller: hotkeys)
            launchAtLoginSection
            dictionarySection
            blockedAppsSection
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 650)
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }

    private var launchAtLoginSection: some View {
        Section {
            Toggle("Запускать при входе", isOn: launchAtLoginBinding)
            if let message = launchAtLogin.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if launchAtLogin.status == .requiresApproval {
                Button("Открыть «Объекты входа»") { launchAtLogin.openSystemSettings() }
            }
            if let message = launchAtLogin.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var dictionarySection: some View {
        Section("Словарь исключений (не конвертировать)") {
            ForEach(personalDictionary.words, id: \.self) { word in
                HStack {
                    Text(word)
                    Spacer()
                    Button("Удалить") {
                        personalDictionary.remove(word)
                    }
                }
            }
            HStack {
                TextField("слово", text: $newExceptionWord)
                Button("Добавить") {
                    personalDictionary.add(newExceptionWord)
                    newExceptionWord = ""
                }
                .disabled(newExceptionWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
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
            get: { launchAtLogin.isRegistered },
            set: { launchAtLogin.setEnabled($0) }
        )
    }
}
