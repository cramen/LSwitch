import AppKit
import LSwitchCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct LocalAppProfilesView: View {
    @ObservedObject var profiles: LocalAppProfiles
    @State private var bundleID = ""
    @State private var mode = LocalAppMode.builtIn
    @State private var message: String?

    var body: some View {
        Section("Профили приложений") {
            Text("Выберите способ исправления для конкретного приложения. Изменения действуют сразу после сохранения.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(profiles.profiles.keys.sorted(), id: \.self) { identifier in
                VStack(alignment: .leading) {
                    Text(applicationName(identifier)).font(.headline)
                    Text(identifier).font(.caption).foregroundStyle(.secondary)
                    Text(profiles.mode(for: identifier).title)
                    HStack {
                        Button("Изменить") {
                            bundleID = identifier
                            mode = profiles.mode(for: identifier)
                            message = nil
                        }
                        Button("Сбросить профиль") {
                            profiles.set(.builtIn, for: identifier)
                            if normalizedID == identifier { mode = .builtIn }
                            message = "Встроенный профиль восстановлен."
                        }
                    }
                }
            }
            Button("Выбрать приложение…") { chooseApplication() }
            TextField("Bundle ID", text: $bundleID, prompt: Text("com.example.app"))
                .onChange(of: bundleID) { _ in message = nil }
            Picker("Способ исправления", selection: $mode) {
                ForEach(LocalAppMode.allCases) { value in Text(value.title).tag(value) }
            }.onChange(of: mode) { _ in message = nil }
            if let restriction { Text(restriction).font(.caption).foregroundStyle(.secondary) }
            Button("Сохранить профиль") {
                message = profiles.set(mode, for: normalizedID)
                    ? "Профиль сохранён. Следующее исправление использует новый режим."
                    : "Проверьте bundle ID. Можно сохранить до 128 профилей."
            }.disabled(!LocalAppProfiles.validBundleID(normalizedID))
            if let message { Text(message).font(.caption) }
        }
    }

    private var normalizedID: String { bundleID.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var restriction: String? {
        if AppRules.presetBlockedApps.contains(normalizedID) {
            return "Терминалы исключены из исправления независимо от профиля."
        }
        if normalizedID == "com.microsoft.VSCode" {
            return "Для VS Code действует защитный запрет: локальный профиль его не снимает."
        }
        if mode == .accessibility, AppProfiles().prefersClipboard(bundleID: normalizedID) {
            return "Прямая AX-запись в этом приложении ненадёжна. Этот режим будет безопасно отклонён."
        }
        return "Профиль не отменяет исключения приложений и проверки сохранности текста."
    }

    private func applicationName(_ identifier: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?
            .deletingPathExtension().lastPathComponent ?? identifier
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Выберите приложение для профиля LSwitch"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let identifier = Bundle(url: url)?.bundleIdentifier else { return }
        bundleID = identifier
        mode = profiles.mode(for: identifier)
        message = nil
    }
}
