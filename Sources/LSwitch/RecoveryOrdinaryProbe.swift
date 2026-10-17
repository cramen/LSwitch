import AppKit
import CoreGraphics
import LSwitchCore

@MainActor
enum RecoveryOrdinaryProbe {
    static func runIfRequested(arguments: [String]) -> Int32? {
        let prefix = "--recovery-ordinary-probe="
        let values = arguments.filter { $0.hasPrefix(prefix) }
        guard !values.isEmpty else { return nil }
        #if DEBUG
        guard values.count == 1, let value = values.first,
              let mode = RecoveryOrdinaryMode(rawValue: String(value.dropFirst(prefix.count))),
              Bundle.main.bundleIdentifier == "ru.cramen.lswitch" else { return 2 }
        let controller = RecoveryOrdinaryProbeController(mode: mode)
        return withExtendedLifetime(controller) { controller.run() }
        #else
        return 2
        #endif
    }
}

#if DEBUG
enum RecoveryOrdinaryMode: String { case control, flush, retain }
enum RecoveryOrdinaryStage: String {
    case ready, configuring, selecting, waitingFocus, arming, capturing, committing
    case observing, continuing, retainedObservation, interactive, finishing
}

@MainActor
final class RecoveryOrdinaryProbeController: NSObject, NSApplicationDelegate {
    let mode: RecoveryOrdinaryMode
    let peer = RecoveryIsolationChildProcess()
    let recoveryWindow = RecoveryWindowController()
    let startedAt = DispatchTime.now().uptimeNanoseconds
    var owner: RecoveryOrdinaryDiagnostic?
    var markers: RecoveryIsolationFixtureMarkers?
    var stage = RecoveryOrdinaryStage.ready
    var timer: Timer?
    var expectedSequence = 0
    var pendingSnapshot = false
    var nextSnapshotAt: UInt64 = 0
    var observedAt: UInt64?
    var observationStartedAt: UInt64?
    var lastReply: IsolationChildMessage?
    var postedPrefix = 0
    var postedControl = 0
    var postedContinuation = 0
    var initialFlushObserved = false
    var observed = false
    var retainedObserved = false
    var finished = false
    var shutdownFinished = false
    var cleanupInProgress = false
    var cleanupCompleted = false
    var childEOF = false
    var childExit: Int32?
    var childStderr = 0
    var finalReply = false
    var childAborted = false
    var launched = false
    var pendingFinishReason: String?
    var retentionInProgress = false
    var quitPrompt = false
    var quitDeclined = false
    var quitAuthorized = false
    var status = "starting"

    init(mode: RecoveryOrdinaryMode) { self.mode = mode; super.init() }

    func run() -> Int32 {
        let application = NSApplication.shared
        guard CGPreflightPostEventAccess() else { status = "post_permission_unavailable"; report(); return 2 }
        let priorDelegate = application.delegate
        let priorPolicy = application.activationPolicy()
        let priorMenu = application.mainMenu
        application.delegate = self
        _ = application.setActivationPolicy(.accessory)
        installMenu()
        repeat {
            application.run()
            if !shutdownFinished { finish("event_loop_stopped") }
        } while !shutdownFinished
        application.delegate = priorDelegate
        _ = application.setActivationPolicy(priorPolicy)
        application.mainMenu = priorMenu
        report()
        return observed && cleanupCompleted && finalReply && !childAborted && childExit == 0 ? 0 : 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !launched else { return }
        launched = true
        recoveryWindow.prepare()
        guard let markers = RecoveryIsolationSession.allocateFixtureMarkers() else { return finish("marker_failure") }
        self.markers = markers
        guard peer.start(matrixHelper: true), let owner = RecoveryOrdinaryDiagnostic.make(
            targetPID: peer.processID, wakeMarker: markers.challengeRelease
        ) else { return finish("child_identity_failure") }
        // Внешняя strong регистрация предшествует любому start/reserve/arm.
        self.owner = owner
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitDeclined = false
        finish("operator_finished")
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showRecovery()
        return true
    }

    @objc func reopenRecovery() { showRecovery() }

    @objc func tick() {
        guard !finished else { return }
        consumeMailbox()
        guard !finished else { return }
        if pendingFinishReason != nil { processPendingFinish(); return }
        if stage == .interactive { return }
        guard peer.isRunning, owner?.targetIsCurrent == true else { return finish("child_identity_lost") }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - startedAt < 10_000_000_000 else { return finish("setup_timeout") }
        if let observationStartedAt, now - observationStartedAt >= 2_000_000_000 {
            return finish("observation_timeout")
        }
        if stage == .capturing { checkCapturedPrefix(); return }
        let observing: [RecoveryOrdinaryStage] = [.waitingFocus, .observing, .continuing, .retainedObservation]
        if observing.contains(stage), now >= nextSnapshotAt, !pendingSnapshot { requestSnapshot() }
    }

    func requestSnapshot() {
        guard !finished, !pendingSnapshot, let sequence = peer.send(.snapshot) else {
            return finish("snapshot_send_failed")
        }
        expectedSequence = sequence
        pendingSnapshot = true
        nextSnapshotAt = DispatchTime.now().uptimeNanoseconds + 50_000_000
    }

    func showRecovery() {
        guard let owner, let metadata = owner.metadata else { return }
        owner.show()
        recoveryWindow.show(metadata, actions: owner.actions)
    }

    private func installMenu() {
        let menu = NSMenu()
        let root = NSMenuItem(title: "LSwitch", action: nil, keyEquivalent: "")
        let application = NSMenu(title: "LSwitch")
        application.addItem(NSMenuItem(title: "Показать восстановление", action: #selector(reopenRecovery),
                                      keyEquivalent: "r"))
        application.items.first?.target = self
        application.addItem(NSMenuItem(title: "Завершить", action: #selector(NSApplication.terminate(_:)),
                                      keyEquivalent: "q"))
        root.submenu = application
        menu.addItem(root)
        NSApplication.shared.mainMenu = menu
    }
}
#endif
