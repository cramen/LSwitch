import Foundation
@testable import LSwitchCore
import XCTest

private enum LoginFailure: LocalizedError {
    case alreadyRegistered
    case jobNotFound
    case invalidSignature
    case launchDenied

    var errorDescription: String? {
        switch self {
        case .alreadyRegistered: return "kSMErrorAlreadyRegistered"
        case .jobNotFound: return "kSMErrorJobNotFound"
        case .invalidSignature: return "kSMErrorInvalidSignature"
        case .launchDenied: return "kSMErrorLaunchDeniedByUser"
        }
    }
}

@MainActor
private final class StubLoginService: LaunchAtLoginService {
    var status: LaunchAtLoginStatus
    var registerStatus: LaunchAtLoginStatus? = .enabled
    var unregisterStatus: LaunchAtLoginStatus? = .notRegistered
    var registerError: Error?
    var unregisterError: Error?
    var registerCalls = 0
    var unregisterCalls = 0
    var settingsCalls = 0

    init(status: LaunchAtLoginStatus) { self.status = status }

    func register() throws {
        registerCalls += 1
        if let registerStatus { status = registerStatus }
        if let registerError { throw registerError }
    }

    func unregister() throws {
        unregisterCalls += 1
        if let unregisterStatus { status = unregisterStatus }
        if let unregisterError { throw unregisterError }
    }

    func openSystemSettings() { settingsCalls += 1 }
}

@MainActor
private struct LoginFixture {
    let settings: SettingsStore
    let service: StubLoginService
    let controller: LaunchAtLoginController
}

final class LaunchAtLoginTests: XCTestCase {
    @MainActor
    private func fixture(_ status: LaunchAtLoginStatus, persisted: Bool = false) throws -> LoginFixture {
        let name = "lswitch.tests.login.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.launchAtLogin = persisted
        let service = StubLoginService(status: status)
        return LoginFixture(
            settings: settings,
            service: service,
            controller: LaunchAtLoginController(settings: settings, service: service)
        )
    }

    @MainActor
    func testStaleFalsePreferenceReadsRealEnabledStateWithoutRegisteringAgain() throws {
        let subject = try fixture(.enabled)
        XCTAssertTrue(subject.settings.launchAtLogin)
        XCTAssertTrue(subject.controller.isRegistered)
        subject.controller.setEnabled(true)
        XCTAssertEqual(subject.service.registerCalls, 0)
        XCTAssertNil(subject.controller.errorMessage)
    }

    @MainActor
    func testStaleTruePreferenceReadsUnregisteredStateWithoutUnregisteringAgain() throws {
        let subject = try fixture(.notRegistered, persisted: true)
        XCTAssertFalse(subject.settings.launchAtLogin)
        subject.controller.setEnabled(false)
        XCTAssertEqual(subject.service.unregisterCalls, 0)
        XCTAssertNil(subject.controller.errorMessage)
    }

    @MainActor
    func testRequiresApprovalIsRegisteredButExplicitlyPending() throws {
        let subject = try fixture(.requiresApproval)
        XCTAssertTrue(subject.controller.isRegistered)
        XCTAssertTrue(subject.settings.launchAtLogin)
        XCTAssertEqual(subject.controller.status, .requiresApproval)
        XCTAssertNotNil(subject.controller.statusMessage)
        subject.controller.setEnabled(true)
        XCTAssertEqual(subject.service.registerCalls, 0)
        subject.controller.openSystemSettings()
        XCTAssertEqual(subject.service.settingsCalls, 1)
        subject.controller.setEnabled(false)
        XCTAssertEqual(subject.service.unregisterCalls, 1)
        XCTAssertFalse(subject.settings.launchAtLogin)
    }

    @MainActor
    func testRefreshReconcilesExternalApprovalRevocationAndUnregistration() throws {
        let subject = try fixture(.enabled, persisted: true)
        subject.service.status = .requiresApproval
        subject.controller.refresh()
        XCTAssertEqual(subject.controller.status, .requiresApproval)
        XCTAssertNotNil(subject.controller.statusMessage)
        subject.service.status = .notRegistered
        subject.controller.refresh()
        XCTAssertFalse(subject.settings.launchAtLogin)
        XCTAssertNil(subject.controller.statusMessage)
        XCTAssertEqual(subject.service.registerCalls + subject.service.unregisterCalls, 0)
    }

    @MainActor
    func testRegisterAndUnregisterFollowConfirmedStatus() throws {
        let subject = try fixture(.notRegistered)
        subject.controller.setEnabled(true)
        XCTAssertEqual(subject.controller.status, .enabled)
        XCTAssertTrue(subject.settings.launchAtLogin)
        subject.controller.setEnabled(false)
        XCTAssertEqual(subject.controller.status, .notRegistered)
        XCTAssertFalse(subject.settings.launchAtLogin)
        XCTAssertEqual(subject.service.registerCalls, 1)
        XCTAssertEqual(subject.service.unregisterCalls, 1)
    }

    @MainActor
    func testAlreadyRegisteredRaceUsesPostErrorStatus() throws {
        let subject = try fixture(.notRegistered)
        subject.service.registerError = LoginFailure.alreadyRegistered
        subject.controller.setEnabled(true)
        XCTAssertEqual(subject.service.registerCalls, 1)
        XCTAssertTrue(subject.settings.launchAtLogin)
        XCTAssertNil(subject.controller.errorMessage)
    }

    @MainActor
    func testAlreadyRegisteredRaceKeepsPendingExplanationWithoutSpuriousFailure() throws {
        let subject = try fixture(.notRegistered)
        subject.service.registerStatus = .requiresApproval
        subject.service.registerError = LaunchAtLoginServiceError.alreadyRegistered
        subject.controller.setEnabled(true)
        XCTAssertTrue(subject.settings.launchAtLogin)
        XCTAssertEqual(subject.controller.status, .requiresApproval)
        XCTAssertNotNil(subject.controller.statusMessage)
        XCTAssertNil(subject.controller.errorMessage)
    }

    @MainActor
    func testJobNotFoundRaceUsesPostErrorStatus() throws {
        let subject = try fixture(.enabled, persisted: true)
        subject.service.unregisterError = LoginFailure.jobNotFound
        subject.controller.setEnabled(false)
        XCTAssertEqual(subject.service.unregisterCalls, 1)
        XCTAssertFalse(subject.settings.launchAtLogin)
        XCTAssertNil(subject.controller.errorMessage)
    }

    @MainActor
    func testRegistrationFailureStaysVisibleAndCanBeRetried() throws {
        let subject = try fixture(.notRegistered)
        subject.service.registerStatus = nil
        subject.service.registerError = LoginFailure.invalidSignature
        subject.controller.setEnabled(true)
        XCTAssertFalse(subject.settings.launchAtLogin)
        XCTAssertTrue(subject.controller.errorMessage?.contains("kSMErrorInvalidSignature") == true)
        subject.service.registerError = nil
        subject.service.registerStatus = .enabled
        subject.controller.setEnabled(true)
        XCTAssertTrue(subject.settings.launchAtLogin)
        XCTAssertNil(subject.controller.errorMessage)
    }

    @MainActor
    func testUnregisterFailureKeepsActualRegistrationAndVisibleError() throws {
        let subject = try fixture(.enabled, persisted: true)
        subject.service.unregisterStatus = nil
        subject.service.unregisterError = LoginFailure.launchDenied
        subject.controller.setEnabled(false)
        XCTAssertTrue(subject.settings.launchAtLogin)
        XCTAssertEqual(subject.controller.status, .enabled)
        XCTAssertNotNil(subject.controller.errorMessage)
    }

    @MainActor
    func testDeniedRegistrationCanRemainPendingWithoutClaimingEnabled() throws {
        let subject = try fixture(.notRegistered)
        subject.service.registerStatus = .requiresApproval
        subject.service.registerError = LoginFailure.launchDenied
        subject.controller.setEnabled(true)
        XCTAssertTrue(subject.settings.launchAtLogin)
        XCTAssertEqual(subject.controller.status, .requiresApproval)
        XCTAssertNotNil(subject.controller.statusMessage)
        XCTAssertNotNil(subject.controller.errorMessage)
    }

    @MainActor
    func testSuccessWithoutSystemStateChangeDoesNotSaveRequestedState() throws {
        let subject = try fixture(.notRegistered)
        subject.service.registerStatus = nil
        subject.controller.setEnabled(true)
        XCTAssertFalse(subject.settings.launchAtLogin)
        XCTAssertNotNil(subject.controller.errorMessage)
        subject.service.status = .enabled
        subject.service.unregisterStatus = nil
        subject.controller.setEnabled(false)
        XCTAssertTrue(subject.settings.launchAtLogin)
        XCTAssertNotNil(subject.controller.errorMessage)
    }

    @MainActor
    func testNotFoundIsDistinctFromConfirmedUnregistration() throws {
        let subject = try fixture(.notFound, persisted: true)
        XCTAssertEqual(subject.controller.status, .notFound)
        XCTAssertFalse(subject.settings.launchAtLogin)
        XCTAssertNotNil(subject.controller.statusMessage)
        subject.controller.setEnabled(false)
        XCTAssertEqual(subject.service.unregisterCalls, 0)
        subject.controller.setEnabled(true)
        XCTAssertEqual(subject.service.registerCalls, 1)
        XCTAssertEqual(subject.controller.status, .enabled)
    }
}
