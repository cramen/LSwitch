import Combine
import Foundation

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    /// Регистрация существует и при ожидании разрешения; это не обещание фактического запуска.
    public var isRegistered: Bool {
        self == .enabled || self == .requiresApproval
    }
}

/// Нормализованный ответ системного адаптера, отличимый от отказа пользователя.
public enum LaunchAtLoginServiceError: LocalizedError, Equatable {
    case alreadyRegistered

    public var errorDescription: String? { "Автозапуск уже зарегистрирован." }
}

@MainActor
public protocol LaunchAtLoginService {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// Сохранённый bool отражает регистрацию; разрешённость запуска показывается отдельным статусом.
@MainActor
public final class LaunchAtLoginController: ObservableObject {
    @Published public private(set) var status: LaunchAtLoginStatus = .notRegistered
    @Published public private(set) var errorMessage: String?

    private let settings: SettingsStore
    private let service: any LaunchAtLoginService

    public convenience init(settings: SettingsStore) {
        self.init(settings: settings, service: SystemLaunchAtLoginService())
    }

    public init(settings: SettingsStore, service: any LaunchAtLoginService) {
        self.settings = settings
        self.service = service
        refresh()
    }

    public var isRegistered: Bool { status.isRegistered }

    public var statusMessage: String? {
        switch status {
        case .enabled, .notRegistered:
            return nil
        case .requiresApproval:
            return "Автозапуск зарегистрирован, но macOS требует разрешение в разделе «Объекты входа»."
        case .notFound:
            return "macOS не нашла приложение для регистрации автозапуска."
        }
    }

    /// Вызывается при открытии настроек и возвращении из системных настроек.
    public func refresh() {
        let current = service.status
        if current != status { errorMessage = nil }
        status = current
        settings.launchAtLogin = current.isRegistered
    }

    public func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        if enabled && status.isRegistered { return }
        if !enabled && (status == .notRegistered || status == .notFound) { return }
        do {
            if enabled { try service.register() } else { try service.unregister() }
            refresh()
            if enabled && status == .requiresApproval { return }
            if !confirmed(enabled) {
                errorMessage = "macOS не подтвердила изменение регистрации автозапуска."
            }
        } catch {
            refresh()
            // Уже достигнутое состояние разрешает гонки AlreadyRegistered/JobNotFound.
            guard !confirmed(enabled) else { return }
            if enabled, status.isRegistered, error as? LaunchAtLoginServiceError == .alreadyRegistered { return }
            errorMessage = "Не удалось изменить автозапуск: \(error.localizedDescription)"
        }
    }

    public func openSystemSettings() {
        service.openSystemSettings()
    }

    private func confirmed(_ enabled: Bool) -> Bool {
        enabled ? status == .enabled : status == .notRegistered
    }
}
