import AppKit
import LSwitchCore

/// Два собственных процесса и фиксированные пакеты. Штатный AppDelegate не запускается.
@MainActor
enum RecoveryIsolationProbe {
    static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.contains("--recovery-isolation-probe") else { return nil }
        #if DEBUG
        guard Bundle.main.bundleIdentifier == "ru.cramen.lswitch" else { return 2 }
        return RecoveryIsolationProbeController().run()
        #else
        return 2
        #endif
    }
}

#if DEBUG
enum IsolationProbeStage: String {
    case ready, configuring, focusing, startingDriver, selecting, capturing
    case prefixSnapshot, challengeSnapshot, interactive, captureFailureSnapshot, closing
}

@MainActor
final class RecoveryIsolationProbeController: NSObject, NSApplicationDelegate {
    let peer = RecoveryIsolationChildProcess()
    let recoveryWindow = RecoveryWindowController()
    let started = DispatchTime.now().uptimeNanoseconds
    var markers: RecoveryIsolationFixtureMarkers?
    var session: RecoveryIsolationSession?
    var driver: RecipientTapDriver?
    var captureTap: EventTapCore?
    var timer: Timer?
    var stage = IsolationProbeStage.ready
    var stageBeforeCleanup: IsolationProbeStage?
    var expectedSequence = 0
    var lastReply: IsolationChildMessage?
    var childBeforeCleanup: IsolationChildMessage?
    var nextFocusRequestAt: UInt64 = 0
    var snapshotPending = false
    var prefixPostedAt: UInt64?
    var challengePostedAt: UInt64?
    var challengeMatchedAt: UInt64?
    var status = "starting"
    var finished = false
    var cleanupCompleted = false
    var childStderrBytes = 0
    var childExitStatus: Int32?
    var peerLossObserved = false
    var peerQuitRequested = false
    var childAbortObserved = false
    var prefixUnchanged = false
    var challengeBlocked = false
    var postedPrefixCount = 0
    var postedChallengeCount = 0
    var driverBeforeCleanup: RecipientTapDriverSnapshot?
    var sessionBeforeCleanup: RecoveryIsolationReport?

    func run() -> Int32 {
        let application = NSApplication.shared
        guard CGPreflightListenEventAccess(), CGPreflightPostEventAccess() else { return 2 }
        let previousDelegate = application.delegate
        let previousMenu = application.mainMenu
        let previousPolicy = application.activationPolicy()
        application.delegate = self
        application.mainMenu = makeMenu()
        _ = application.setActivationPolicy(.accessory)
        application.run()
        application.delegate = previousDelegate
        application.mainMenu = previousMenu
        _ = application.setActivationPolicy(previousPolicy)
        printReport(event: "final")
        return cleanupCompleted && prefixUnchanged && challengeBlocked && !childAbortObserved
            && childExitStatus == 0 && status == "operator_finished" ? 0 : 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        recoveryWindow.prepare()
        guard let markers = RecoveryIsolationSession.allocateFixtureMarkers() else { return finish("markers_failed") }
        self.markers = markers
        guard peer.start() else { return finish("child_start_failed") }
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finish("operator_finished")
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func tick() {
        guard !finished, consumeMailbox() else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if now - started > 120_000_000_000 { return finish("fixture_timeout") }
        if stage != .interactive, now - started > 10_000_000_000 { return finish("setup_timeout") }
        if stage == .focusing, now >= nextFocusRequestAt { requestFocusSnapshot(now: now) }
        if stage == .capturing { observeCapture(now: now) }
        if stage == .challengeSnapshot, now >= nextFocusRequestAt { requestChallengeSnapshot(now: now) }
    }

    private func consumeMailbox() -> Bool {
        guard let mailbox = peer.take() else { return true }
        childStderrBytes = mailbox.stderrBytes
        childExitStatus = mailbox.exitStatus ?? childExitStatus
        if let failure = mailbox.failure { finish(failure); return false }
        for message in mailbox.messages {
            handle(message)
            if finished { return false }
        }
        if mailbox.eof { handlePeerLoss() }
        return !finished
    }

    func handlePeerLoss() {
        guard !peerLossObserved else { return }
        peerLossObserved = true
        driver?.markPeerEOF()
        session?.markPeerUnavailable()
        if stage == .interactive {
            showRecovery()
            printReport(event: "peer_lost_retained")
        } else { finish("peer_lost_before_interactive") }
    }

    @objc func closeReceiver() {
        guard stage == .interactive, !peerLossObserved, !peerQuitRequested else { return }
        peerQuitRequested = peer.send(.quit) != nil
    }

    @objc func showRecovery() {
        guard let session, let metadata = session.metadata else { return }
        session.show()
        recoveryWindow.show(metadata, actions: session.actions)
    }

    func finish(_ result: String) {
        guard !finished else { return }
        finished = true
        status = result
        stageBeforeCleanup = stage
        childBeforeCleanup = lastReply
        stage = .closing
        timer?.invalidate()
        timer = nil
        sessionBeforeCleanup = session?.report
        driverBeforeCleanup = driver?.snapshot
        captureTap?.stop()
        recoveryWindow.hide()
        // EOF — отдельный штатный shutdown child; не повторяем quit в уже закрывающийся pipe.
        peer.closeInput()
        Task {
            for _ in 0..<20 where peer.isRunning { try? await Task.sleep(nanoseconds: 25_000_000) }
            if peer.isRunning { peer.terminateIfRunning() }
            for _ in 0..<10 where peer.isRunning { try? await Task.sleep(nanoseconds: 25_000_000) }
            // Quarantine снимается только после завершения собственного child.
            let stopped = !peer.isRunning ? await driver?.stop() ?? true : false
            consumeFinalMailbox()
            cleanupCompleted = stopped && !peer.isRunning
            if !cleanupCompleted { status = "cleanup_unconfirmed" }
            let application = NSApplication.shared
            application.stop(nil)
            if let wake = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
            ) { application.postEvent(wake, atStart: false) }
        }
    }

    private func consumeFinalMailbox() {
        if let final = peer.take() {
            if let failure = final.failure { childAbortObserved = true; status = failure }
            childExitStatus = final.exitStatus ?? childExitStatus
            childStderrBytes = final.stderrBytes
            for message in final.messages where message.kind == "exiting" {
                if !controlledExit(message) { childAbortObserved = true }
                lastReply = message
            }
        }
        childExitStatus = peer.exitStatus ?? childExitStatus
        if childExitStatus != 0 { childAbortObserved = true }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "LSwitch Isolation", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "LSwitch Isolation")
        item.submenu = submenu
        menu.addItem(item)
        addCommand("Показать восстановление", action: #selector(showRecovery), key: "r", to: submenu)
        addCommand("Закрыть тестовый приёмник", action: #selector(closeReceiver), key: "e", to: submenu)
        submenu.addItem(withTitle: "Завершить проверку",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        let commands = NSMenu(title: "Правка")
        edit.submenu = commands
        menu.addItem(edit)
        commands.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        commands.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        commands.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private func addCommand(_ title: String, action: Selector, key: String, to menu: NSMenu) {
        let command = NSMenuItem(title: title, action: action, keyEquivalent: key)
        command.target = self
        menu.addItem(command)
    }
}
#endif
