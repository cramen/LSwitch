import AppKit
import CoreGraphics
import LSwitchCore

@MainActor
enum RecoverySystemFaultProbe {
    static func runIfRequested(arguments: [String]) -> Int32? {
        let flag = "--recovery-system-fault"
        let prefix = flag + "="
        let values = arguments.filter { $0.hasPrefix(prefix) }
        guard !values.isEmpty || arguments.contains(flag) else { return nil }
        #if DEBUG
        guard !arguments.contains(flag), values.count == 1, let value = values.first,
              let mode = RecoverySystemFaultMode(rawValue: String(value.dropFirst(prefix.count))),
              Bundle.main.bundleIdentifier == "ru.cramen.lswitch" else { return 2 }
        let controller = RecoverySystemFaultProbeController(mode: mode)
        return withExtendedLifetime(controller) { controller.run() }
        #else
        return 2
        #endif
    }
}

#if DEBUG
enum RecoverySystemFaultPhase: String {
    case ready, configuring, selecting, waitingFocus, starting, capturing
    case secureBefore, secureAfter, disabling, observingBefore, observingAfter, stoppingSecure
    case interactive, finishing
}

@MainActor
final class RecoverySystemFaultProbeController: NSObject, NSApplicationDelegate {
    let mode: RecoverySystemFaultMode
    let peer = RecoveryIsolationChildProcess()
    let window = RecoveryWindowController()
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let continuation = RecoverySystemFaultContinuation()
    var owner: RecoverySystemFaultDiagnostic?
    var markers: RecoveryIsolationFixtureMarkers?
    var phase = RecoverySystemFaultPhase.ready
    var timer: Timer?
    var expectedSequence = 0
    var awaitingReply = false
    var nextSnapshotAt: UInt64 = 0
    var lastReply: IsolationChildMessage?
    var postedPrefix = 0
    var postedLate = 0
    var balancingReleases = 0
    var keyboardDebtUnresolved = false
    var pairInconclusive = false
    var beforeArmRefused = false
    var observed = false
    var secureBalanced = true
    var finished = false
    var shutdownFinished = false
    var quitPending = false
    var retirementPending = false
    var childEOF = false
    var childExit: Int32?
    var finalReply = false
    var childAborted = false
    var cleanupCompleted = false
    var status = "starting"

    init(mode: RecoverySystemFaultMode) { self.mode = mode; super.init() }

    func run() -> Int32 {
        guard CGPreflightPostEventAccess(), CGPreflightListenEventAccess() else { return 2 }
        let application = NSApplication.shared
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
        return observed && secureBalanced && cleanupCompleted && finalReply && childExit == 0 && !childAborted
            && !peer.secureWatchdogFired && !keyboardDebtUnresolved && !pairInconclusive ? 0 : 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard owner == nil else { return }
        window.prepare()
        guard let markers = RecoveryIsolationSession.allocateFixtureMarkers(), peer.start(matrixHelper: true),
              let owner = RecoverySystemFaultDiagnostic.make(targetPID: peer.processID, markers: markers) else {
            return finish("setup_refused")
        }
        self.markers = markers
        self.owner = owner
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finish("operator_finished")
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func reopenRecovery() {
        guard let owner, let metadata = owner.metadata else { return }
        owner.show()
        window.show(metadata, actions: owner.actions)
    }

    @objc func tick() {
        guard !finished else { return }
        consumeMailbox()
        guard permitsForwardProgress, phase != .interactive, !retirementPending else { return }
        guard peer.isRunning, owner?.targetIsCurrent == true else { return finish("child_lost") }
        guard DispatchTime.now().uptimeNanoseconds - startedAt < 10_000_000_000 else {
            return finish("watchdog")
        }
        if phase == .capturing { checkCaptured(); return }
        if [.waitingFocus, .observingBefore, .observingAfter].contains(phase),
           !awaitingReply, DispatchTime.now().uptimeNanoseconds >= nextSnapshotAt { sendSnapshot() }
    }

    func send(_ command: RecoveryIsolationCommand, next: RecoverySystemFaultPhase) {
        guard permitsForwardProgress else { return }
        var sequence: Int?
        let sent = continuation.prepareThenSend(prepare: {
            command != .secureInputOn || self.peer.armSecureWatchdog()
        }, send: {
            guard self.permitsForwardProgress else { return false }
            sequence = self.peer.send(command)
            return sequence != nil
        })
        guard sent, let sequence else { return finish("send_or_watchdog_refused") }
        guard permitsForwardProgress else { return }
        expectedSequence = sequence
        awaitingReply = true
        phase = next
    }

    var permitsForwardProgress: Bool { continuation.isOpen && !finished && !quitPending }

    func sendSnapshot() {
        guard permitsForwardProgress, !awaitingReply else { return }
        send(.snapshot, next: phase)
        nextSnapshotAt = DispatchTime.now().uptimeNanoseconds + 40_000_000
    }

    private func installMenu() {
        let menu = NSMenu()
        let root = NSMenuItem(title: "LSwitch", action: nil, keyEquivalent: "")
        let actions = NSMenu(title: "LSwitch")
        let show = NSMenuItem(title: "Показать восстановление", action: #selector(reopenRecovery), keyEquivalent: "r")
        show.target = self
        actions.addItem(show)
        actions.addItem(NSMenuItem(title: "Завершить", action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        root.submenu = actions
        menu.addItem(root)
        NSApplication.shared.mainMenu = menu
    }
}
#endif
