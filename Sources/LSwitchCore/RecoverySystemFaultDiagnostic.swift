#if DEBUG
import Foundation

public enum RecoverySystemFaultMode: String, CaseIterable, Sendable {
    case control
    case secureBeforeArm = "secure-before-arm"
    case secureAfterCapture = "secure-after-capture"
    case secureCaptureWindow = "secure-capture-window"
    case headBeforeArm = "head-before-arm"
    case headAfterCapture = "head-after-capture"
    case tailAfterCapture = "tail-after-capture"
}

/// Только фиксированный diagnostic flow. Реальный capture остаётся у существующей Session.
@MainActor
protocol RecoverySystemFaultDriver: RecoveryIsolationProtecting {
    var snapshot: RecipientTapDriverSnapshot { get }
    func start() async -> Bool
    func stop() async -> Bool
    func disableOwnedTapForDiagnostics(_ tap: RecipientDiagnosticTap) async -> Bool
    func bindFixtureCapture(router: RecoveryCaptureRouter, filter: RecoveryFixtureCaptureFilter) -> Bool
}

extension RecipientTapDriver: RecoverySystemFaultDriver {}

public struct RecoverySystemFaultReport: Sendable {
    public let started: Bool
    public let armAttempted: Bool
    public let armed: Bool
    public let observedSecure: Bool
    public let faultLatched: Bool
    public let disableRequested: Bool
    public let disableConfirmed: Bool
    public let session: RecoveryIsolationReport
    public let driver: RecipientTapDriverSnapshot
    public let privacyGuardAccepted = false
    public let productionEnabled = false
}

@MainActor
public final class RecoverySystemFaultDiagnostic {
    private let session: RecoveryIsolationSession
    private let driver: any RecoverySystemFaultDriver
    private var startAttempted = false
    private var started = false
    private var armAttempted = false
    private var armed = false
    private var observedSecure = false
    private var faultLatched = false
    private var disableRequested = false
    private var disableConfirmed = false

    init?(session: RecoveryIsolationSession, driver: any RecoverySystemFaultDriver) {
        guard session.bridge === driver.bridge else { return nil }
        self.session = session
        self.driver = driver
    }

    public static func make(
        targetPID: Int32, markers: RecoveryIsolationFixtureMarkers
    ) -> RecoverySystemFaultDiagnostic? {
        guard let session = RecoveryIsolationSession.make(
            targetPID: targetPID, prefixDownMarker: markers.prefixDown, prefixReleaseMarker: markers.prefixRelease
        ), let driver = RecipientTapDriver(bridge: session.bridge) else { return nil }
        return .init(session: session, driver: driver)
    }

    public var targetIsCurrent: Bool { session.targetIsCurrent }
    public var captureIsCurrent: Bool { !faultLatched && session.captureIsCurrentForDiagnostics() }
    public var hasPendingInput: Bool { session.report.retainedBeforeAdoption || session.report.adopted }

    public func start() async -> Bool {
        guard !startAttempted, !faultLatched, targetIsCurrent, !Task.isCancelled else { return false }
        startAttempted = true
        let ready = await driver.start()
        started = ready && !faultLatched && targetIsCurrent && !Task.isCancelled
        return started
    }

    public func arm() -> Bool {
        guard started, !armAttempted, !faultLatched, targetIsCurrent, !Task.isCancelled else { return false }
        armAttempted = true
        armed = session.prepareRecipientCapture(protection: driver, bind: { router, filter in
            self.driver.bindFixtureCapture(router: router, filter: filter)
        })
        return armed && !faultLatched && targetIsCurrent
    }

    /// Ответ own-child является явным diagnostic fault, не системным production guard.
    public func observeSecureInput(enabled: Bool) {
        guard enabled else { return }
        observedSecure = true
        faultLatched = true
        session.markPeerUnavailable()
    }

    public func disable(_ tap: RecipientDiagnosticTap) async -> Bool {
        guard started, !disableRequested, targetIsCurrent else { return false }
        disableRequested = true
        faultLatched = true
        session.markPeerUnavailable()
        disableConfirmed = await driver.disableOwnedTapForDiagnostics(tap)
        return disableConfirmed
    }

    public func retireForStorage() -> Bool {
        guard hasPendingInput else { return false }
        faultLatched = true
        session.markPeerUnavailable()
        return session.finishForStorageRecovery()
    }

    public func stop() async -> Bool { await driver.stop() }
    public func show() { session.show() }
    public var metadata: RecoveryWindowMetadata? { session.metadata }
    public var actions: RecoveryWindowActions { session.actions }
    public var quitActions: RecoveryQuitActions { session.quitActions }
    public var report: RecoverySystemFaultReport {
        .init(started: started, armAttempted: armAttempted, armed: armed, observedSecure: observedSecure,
              faultLatched: faultLatched, disableRequested: disableRequested, disableConfirmed: disableConfirmed,
              session: session.report, driver: driver.snapshot)
    }
}
#endif
