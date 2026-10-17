import AppKit
import CoreGraphics
import LSwitchCore

/// Только собственный дочерний редактор. Обычный AppDelegate и capture не запускаются.
@MainActor
enum RecoveryEventMatrixProbe {
    static func runIfRequested(arguments: [String]) -> Int32? {
        let values = arguments.filter { $0.hasPrefix("--recovery-event-matrix=") }
        guard !values.isEmpty else { return nil }
        #if DEBUG
        guard values.count == 1, let value = values.first,
              let mode = RecoveryEventMatrixMode(rawValue: String(value.dropFirst("--recovery-event-matrix=".count))),
              Bundle.main.bundleIdentifier == "ru.cramen.lswitch" else { return 2 }
        let routes = arguments.filter { $0.hasPrefix("--recovery-event-matrix-route=") }
        guard routes.count <= 1,
              let route = MatrixKeyboardRoute(rawValue: routes.first.map {
                  String($0.dropFirst("--recovery-event-matrix-route=".count))
              } ?? "recipient") else { return 2 }
        let controller = RecoveryEventMatrixController(
            mode: mode, keyboardOnly: arguments.contains("--recovery-event-matrix-keyboard-only"), route: route
        )
        return withExtendedLifetime(controller) { controller.run() }
        #else
        return 2
        #endif
    }
}

#if DEBUG
enum RecoveryEventMatrixMode: String { case control, protected, closed, lost }
enum MatrixKeyboardRoute: String { case recipient, session }
enum RecoveryEventMatrixStage: String { case ready, configuring, arming, preparing, observing, interactive, finishing }

@MainActor
final class RecoveryEventMatrixController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let mode: RecoveryEventMatrixMode
    let keyboardOnly: Bool
    let keyboardRoute: MatrixKeyboardRoute
    let peer = RecoveryIsolationChildProcess()
    let started = DispatchTime.now().uptimeNanoseconds
    var anchor: RecoveryIsolationSession?
    var driver: RecipientTapDriver?
    var driverBeforeCleanup: RecipientTapDriverSnapshot?
    var markers: RecoveryIsolationFixtureMarkers?
    var stage = RecoveryEventMatrixStage.ready
    var expectedSequence = 0
    var pendingSnapshot = false
    var finishingAfterSnapshot = false
    var postedCount = 0
    var balancingReleases = 0
    var keyboardDebtUnresolved = false
    var lastReply: IsolationChildMessage?
    var childEOF = false
    var childExit: Int32?
    var childStderr = 0
    var finalReply = false
    var cleanupCompleted = false
    var shutdownAttemptFinished = false
    var finished = false
    var status = "starting"
    var timer: Timer?
    var window: NSWindow?
    private var inputField: NSTextField?

    init(mode: RecoveryEventMatrixMode, keyboardOnly: Bool, route: MatrixKeyboardRoute) {
        self.mode = mode
        self.keyboardOnly = keyboardOnly
        keyboardRoute = route
        super.init()
    }

    func run() -> Int32 {
        guard CGPreflightPostEventAccess() else { status = "post_permission_unavailable"; report(); return 2 }
        let application = NSApplication.shared
        let oldDelegate = application.delegate
        let oldPolicy = application.activationPolicy()
        application.delegate = self
        _ = application.setActivationPolicy(.accessory)
        application.run()
        if !finished { finish("event_loop_stopped") }
        while !shutdownAttemptFinished { application.run() }
        application.delegate = oldDelegate
        _ = application.setActivationPolicy(oldPolicy)
        report()
        let completed = status == "operator_finished" || status == "keyboard_observation_complete"
        return completed && childEOF && finalReply && childExit == 0 ? 0 : 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        prepareWindow()
        guard let markers = RecoveryIsolationSession.allocateFixtureMarkers() else { return finish("marker_failure") }
        self.markers = markers
        guard peer.start(matrixHelper: true), let anchor = RecoveryIsolationSession.make(
            targetPID: peer.processID, prefixDownMarker: markers.prefixDown, prefixReleaseMarker: markers.prefixRelease
        ) else { return finish("child_identity_failure") }
        self.anchor = anchor
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finish("operator_finished")
        return .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { finish("operator_finished"); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func tick() {
        guard !finished else { return }
        consumeMailbox()
        guard !finished else { return }
        guard peer.isRunning, anchor?.targetIsCurrent == true else { return finish("child_identity_lost") }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        if elapsed >= 600_000_000_000 { finish("matrix_timeout") }
        if stage != .interactive, elapsed >= 15_000_000_000 { finish("setup_timeout") }
    }

    @objc func requestSnapshot() {
        guard stage == .interactive || stage == .observing, !finished, !pendingSnapshot else { return }
        guard let sequence = peer.send(.snapshot) else { return finish("snapshot_failed") }
        expectedSequence = sequence
        pendingSnapshot = true
    }

    @objc func requestFinish() {
        guard stage == .interactive, !pendingSnapshot else { return }
        finishingAfterSnapshot = true
        requestSnapshot()
    }

    @objc private func focusParentWindow() {
        guard !finished, let window, let inputField else { return }
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(inputField)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func focusReceiverWindow() {
        guard !finished, peer.isRunning, anchor?.targetIsCurrent == true,
              let receiver = NSRunningApplication(processIdentifier: peer.processID) else { return }
        _ = receiver.activate(options: [.activateIgnoringOtherApps])
    }

    private func prepareWindow() {
        let frame = NSRect(x: 80, y: 100, width: 540, height: 250)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LSwitch Event Matrix \(mode.rawValue)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let label = NSTextField(wrappingLabelWithString:
            "Собственный тестовый редактор: \(mode.rawValue). Проверяйте мышь только внутри его текстового поля.")
        label.frame = NSRect(x: 20, y: 185, width: 500, height: 45)
        let input = NSTextField(frame: NSRect(x: 20, y: 135, width: 500, height: 28))
        input.placeholderString = "Тест ввода в другом процессе"
        inputField = input
        let parentFocus = NSButton(title: "Работать в этом окне", target: self, action: #selector(focusParentWindow))
        parentFocus.frame = NSRect(x: 20, y: 80, width: 235, height: 36)
        let childFocus = NSButton(title: "Показать редактор", target: self, action: #selector(focusReceiverWindow))
        childFocus.frame = NSRect(x: 275, y: 80, width: 245, height: 36)
        let snapshot = NSButton(title: "Снять показания", target: self, action: #selector(requestSnapshot))
        snapshot.frame = NSRect(x: 20, y: 30, width: 190, height: 36)
        let finish = NSButton(title: "Завершить проверку", target: self, action: #selector(requestFinish))
        finish.frame = NSRect(x: 270, y: 30, width: 250, height: 36)
        for view in [label, input, parentFocus, childFocus, snapshot, finish] { content.addSubview(view) }
        window.contentView = content
        self.window = window
        window.orderFront(nil)
    }
}
#endif
