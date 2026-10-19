import Carbon
import Combine
import Foundation

/// Регистрация проверяется до изменения настройки. Closure освобождает только собственный hotkey.
@MainActor
public final class HotkeySettingsController: ObservableObject {
    public typealias Register = (ConversionHotkey) -> (() -> Void)?
    @Published public private(set) var message: String?
    @Published public private(set) var activeHotkey: ConversionHotkey
    public var onChange: () -> Void = {}
    private let settings: SettingsStore
    private let register: Register
    private var release: (() -> Void)?
    private var active = false

    public init(settings: SettingsStore, register: Register? = nil) {
        self.settings = settings
        self.register = register ?? { SystemHotkeyRegistration.reserve($0) }
        activeHotkey = settings.conversionHotkey
    }

    @discardableResult
    public func apply(_ hotkey: ConversionHotkey) -> Bool {
        guard hotkey.isValid else {
            message = "Выберите Control или Command с клавишей либо Option+Пробел."
            return false
        }
        if hotkey == activeHotkey, hotkey == settings.conversionHotkey, active {
            message = nil
            return true
        }
        var prepared: (() -> Void)?
        if hotkey.keyCode != nil {
            guard let registration = register(hotkey) else {
                message = "Не удалось зарегистрировать сочетание. Возможно, оно уже занято. Выберите другое."
                return false
            }
            prepared = registration
        }
        release?()
        release = active ? prepared : nil
        if !active { prepared?() }
        activeHotkey = hotkey
        settings.conversionHotkey = hotkey
        message = nil
        onChange()
        return true
    }

    public func setActive(_ enabled: Bool) {
        guard active != enabled else { return }
        active = enabled
        if !enabled { release?(); release = nil; return }
        let saved = settings.conversionHotkey
        // apply не должен пропустить регистрацию сохранённого сочетания при старте.
        activeHotkey = .doubleShift
        if saved == .doubleShift { return }
        if !apply(saved) {
            settings.conversionHotkey = .doubleShift
            activeHotkey = .doubleShift
            message = "Сохранённое сочетание недоступно. Восстановлен двойной Shift."
            onChange()
        }
    }

    deinit { release?() }
}

public enum SystemHotkeyRegistration {
    /// Event tap распознаёт raw keyDown. Carbon только резервирует команду и не запускает её второй раз.
    @MainActor
    public static func reserve(_ hotkey: ConversionHotkey) -> (() -> Void)? {
        guard hotkey.isValid, let keyCode = hotkey.keyCode else { return nil }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x4C535748, id: UInt32(keyCode))
        let status = RegisterEventHotKey(UInt32(keyCode), carbonModifiers(hotkey.modifiers), identifier,
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { return nil }
        var handler: EventHandlerRef?
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in noErr },
                                            types.count, &types, nil, &handler)
        guard installed == noErr, let handler else { UnregisterEventHotKey(reference); return nil }
        return { UnregisterEventHotKey(reference); RemoveEventHandler(handler) }
    }

    private static func carbonModifiers(_ flags: UInt64) -> UInt32 {
        var result: UInt32 = 0
        for (flag, value) in [(CGEventFlags.maskCommand, cmdKey), (.maskControl, controlKey),
                              (.maskAlternate, optionKey), (.maskShift, shiftKey)] where flags & flag.rawValue != 0 {
            result |= UInt32(value)
        }
        return result
    }
}
