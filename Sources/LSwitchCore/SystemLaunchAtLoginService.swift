import Foundation
import ServiceManagement

/// Адаптер относится к main app текущего процесса; внешний диагностический драйвер его не подменяет.
@MainActor
public struct SystemLaunchAtLoginService: LaunchAtLoginService {
    public init() {}

    public var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    public func register() throws {
        do {
            try SMAppService.mainApp.register()
        } catch {
            if (error as NSError).code == Int(kSMErrorAlreadyRegistered) {
                throw LaunchAtLoginServiceError.alreadyRegistered
            }
            throw error
        }
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
