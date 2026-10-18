import CoreGraphics
import LSwitchCore
import SwiftUI

struct HotkeySettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var controller: HotkeySettingsController
    @State private var custom = false
    @State private var keyCode: UInt16 = 40
    @State private var modifiers = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue

    var body: some View {
        Section("Исправление раскладки и откат") {
            Text("Сейчас: \(settings.conversionHotkey.title)")
            Picker("Хоткей", selection: $custom) {
                Text("Двойной Shift").tag(false)
                Text("Сочетание клавиш").tag(true)
            }
            if custom {
                HStack {
                    modifier("⌃", flag: .maskControl)
                    modifier("⌥", flag: .maskAlternate)
                    modifier("⇧", flag: .maskShift)
                    modifier("⌘", flag: .maskCommand)
                    Picker("Клавиша", selection: $keyCode) {
                        ForEach(ConversionHotkey.keys) { key in Text(key.label).tag(key.code) }
                    }.labelsHidden().accessibilityLabel("Клавиша").frame(width: 90)
                }
                Text("Нужен Control или Command. Клавиша выбирается по позиции в латинской раскладке.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Сочетание резервируется глобально. Конфликты с командами приложений могут не обнаруживаться.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Применить") { controller.apply(candidate) }
                    .disabled(!candidate.isValid || candidate == settings.conversionHotkey)
                Button("Вернуть двойной Shift") {
                    if controller.apply(.doubleShift) { custom = false }
                }.disabled(settings.conversionHotkey == .doubleShift)
            }
            if let message = controller.message {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }.onAppear { load() }
    }

    private var candidate: ConversionHotkey {
        custom ? ConversionHotkey(keyCode: keyCode, modifiers: modifiers) : .doubleShift
    }

    private func load() {
        let saved = settings.conversionHotkey
        custom = saved.keyCode != nil
        if let code = saved.keyCode { keyCode = code; modifiers = saved.modifiers }
    }

    private func modifier(_ title: String, flag: CGEventFlags) -> some View {
        Toggle(title, isOn: Binding(get: { modifiers & flag.rawValue != 0 }, set: { enabled in
            if enabled { modifiers |= flag.rawValue } else { modifiers &= ~flag.rawValue }
        }))
        .toggleStyle(.checkbox)
        .accessibilityLabel(modifierName(flag))
    }

    private func modifierName(_ flag: CGEventFlags) -> String {
        switch flag {
        case .maskControl: return "Control"
        case .maskAlternate: return "Option"
        case .maskCommand: return "Command"
        default: return "Shift"
        }
    }
}
