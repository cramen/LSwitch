import AppKit
import Carbon
import Darwin

/// Ранний режим того же подписанного executable; штатный AppDelegate не создаётся.
@MainActor
enum RecoveryIsolationReceiver {
    static func runIfRequested(arguments: [String]) -> Int32? {
        let flag = "--recovery-isolation-receiver"
        guard arguments.contains(flag) else { return nil }
        #if DEBUG
        guard arguments.filter({ $0 == flag }).count == 1,
              ["ru.cramen.lswitch", "ru.cramen.lswitch.receiverprobe"].contains(Bundle.main.bundleIdentifier ?? ""),
              let nonce = argument("--isolation-nonce=", in: arguments), UUID(uuidString: nonce) != nil,
              let sender = argument("--isolation-sender-pid=", in: arguments),
              let senderPID = Int32(sender), senderPID > 0, senderPID == getppid() else { return 2 }
        return RecoveryIsolationReceiverController(nonce: nonce, senderPID: senderPID).run()
        #else
        return 2
        #endif
    }

    #if DEBUG
    private static func argument(_ prefix: String, in arguments: [String]) -> String? {
        let matches = arguments.filter { $0.hasPrefix(prefix) }
        guard matches.count == 1, let value = matches.first else { return nil }
        return String(value.dropFirst(prefix.count))
    }
    #endif
}

#if DEBUG
@MainActor
private final class RecoveryIsolationReceiverController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let nonce: String
    private let senderPID: Int32
    private var channel: RecoveryIsolationPipe?
    private var window: NSWindow?
    private var editor: RecoveryIsolationReceiverView?
    private var matrixSelectItem: NSMenuItem?
    private var secureLease: RecoverySecureInputDiagnosticLease?
    private var secureTimer: Timer?
    private var monitor: Any?
    private var timer: Timer?
    private var lastSequence = 0
    private var configured = false
    private var selected = false
    private var finished = false
    private var exitStatus: Int32 = 1
    private let startedAt = DispatchTime.now().uptimeNanoseconds

    init(nonce: String, senderPID: Int32) {
        self.nonce = nonce
        self.senderPID = senderPID
        super.init()
    }

    func run() -> Int32 {
        // AppKit создаётся до обращения к CGEvent свойствам входящих NSEvent.
        let application = NSApplication.shared
        let priorDelegate = application.delegate
        let priorPolicy = application.activationPolicy()
        let priorMenu = application.mainMenu
        application.delegate = self
        let helper = Bundle.main.bundleIdentifier == "ru.cramen.lswitch.receiverprobe"
        _ = application.setActivationPolicy(helper ? .regular : .accessory)
        defer {
            stopSecureInput()
            application.delegate = priorDelegate
            _ = application.setActivationPolicy(priorPolicy)
            application.mainMenu = priorMenu
        }
        let channel = RecoveryIsolationPipe(nonce: nonce, onRequest: { [weak self] request in
            DispatchQueue.main.async { [weak self] in self?.handle(request) }
        }, onEnd: { [weak self] reason in
            DispatchQueue.main.async { [weak self] in self?.finish(reason) }
        })
        self.channel = channel
        guard channel.start() else { return 2 }
        scheduleDeadline(maximumLifetime: 120)
        application.run()
        if !finished { finish("event_loop_stopped") }
        if !channel.closeAfterDraining() { return 1 }
        return exitStatus
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !finished else { return }
        let frame = NSRect(x: 0, y: 0, width: 560, height: 180)
        let editor = RecoveryIsolationReceiverView(frame: frame)
        editor.prepareFixture()
        editor.onAbort = { [weak self] reason in self?.finish(reason) }
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "LSwitch Isolation Receiver \(nonce)"
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.delegate = self
        self.window = window
        self.editor = editor
        guard installInputMonitor(editor) else { return finish("monitor_unavailable") }
        window.center()
        focusFixture()
        reply("ready", sequence: 0, includeTitle: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finish("application_quit")
        return .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish("window_closed")
        return false
    }

    func applicationDidResignActive(_ notification: Notification) { stopSecureInput() }

    @objc private func secureExpired() { stopSecureInput() }

    private func stopSecureInput() {
        secureTimer?.invalidate()
        secureTimer = nil
        secureLease?.stop()
    }

    private func configureSecureInput(enabled: Bool, sequence: Int) {
        guard configured, let editor, !editor.matrixArmed else { return finish("protocol") }
        if secureLease == nil {
            secureLease = RecoverySecureInputDiagnosticLease(environment: .init(
                isEnabled: { IsSecureEventInputEnabled() },
                enable: { EnableSecureEventInput() == noErr }, disable: { DisableSecureEventInput() == noErr },
                now: { DispatchTime.now().uptimeNanoseconds }
            ))
        }
        if enabled {
            let permitted = NSApp.isActive && window?.isKeyWindow == true && window?.firstResponder === editor
            if secureLease?.begin(permitted: permitted) == true {
                let timer = Timer(timeInterval: 2, target: self, selector: #selector(secureExpired),
                                  userInfo: nil, repeats: false)
                secureTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } else { stopSecureInput() }
        reply("secure_input", sequence: sequence)
    }

    @objc private func timedOut() { finish("timeout") }

    private func handle(_ request: RecoveryIsolationRequest) {
        guard !finished else { return }
        lastSequence = request.sequence
        guard let editor, window != nil else { return finish("protocol") }
        switch request.command {
        case .handshake:
            reply("ready", sequence: request.sequence, includeTitle: true)
        case .configure:
            guard !configured, let markers = request.markers,
                  editor.configure(senderPID: senderPID, markers: markers) else { return finish("protocol") }
            configured = true
            reply("configured", sequence: request.sequence)
        case .selectFixture:
            guard configured, !selected, editor.selectFixture() else { return finish("protocol") }
            selected = true
            focusFixture()
            reply("selected", sequence: request.sequence)
        case .armEventMatrix: armMatrix(editor, sequence: request.sequence)
        case .secureInputOn: configureSecureInput(enabled: true, sequence: request.sequence)
        case .secureInputOff: configureSecureInput(enabled: false, sequence: request.sequence)
        case .snapshot:
            reply("snapshot", sequence: request.sequence)
        case .quit:
            finish("quit")
        }
    }

    private func armMatrix(_ editor: RecoveryIsolationReceiverView, sequence: Int) {
        guard configured, secureLease == nil, !selected, editor.armEventMatrix() else { return finish("protocol") }
        installMatrixMenu()
        scheduleDeadline(maximumLifetime: 600)
        focusFixture()
        reply("matrix_armed", sequence: sequence)
    }

    private func focusFixture() {
        guard let window, let editor else { return }
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(editor)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func installInputMonitor(_ editor: RecoveryIsolationReceiverView) -> Bool {
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .tabletPoint, .tabletProximity, .gesture, .magnify, .swipe, .rotate, .pressure
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak editor] event in
            guard let editor, editor.permitsLocalEvent(event) else { return nil }
            return event
        }
        return monitor != nil
    }

    private func metadata() -> [String: Any] {
        let focused = window?.isKeyWindow == true && window?.firstResponder === editor
        var result: [String: Any] = [
            "fixtureTextUnchanged": editor?.fixtureTextUnchanged ?? false,
            "fixtureSelectionUnchanged": editor?.fixtureSelectionUnchanged ?? false,
            "controlTextMatches": editor?.controlTextMatches ?? false,
            "controlSelectionMatches": editor?.controlSelectionMatches ?? false,
            "received": editor?.received ?? [], "changeCount": editor?.changeCount ?? 0,
            "foreignInput": editor?.foreignInput ?? false, "overflow": editor?.overflow ?? false,
            "active": NSApplication.shared.isActive, "focused": focused
        ]
        if let secureLease {
            let secure = secureLease.snapshot
            result["secure"] = secure.flags
            result["secureCounts"] = secure.counts
        } else if let editor, editor.matrixArmed {
            result["matrixArmed"] = true
            if !editor.matrixLocal.isEmpty { result["matrixLocal"] = editor.matrixLocal }
            if !editor.matrixDispatch.isEmpty { result["matrixDispatch"] = editor.matrixDispatch }
            if !editor.matrixShortcut.isEmpty { result["matrixShortcut"] = editor.matrixShortcut }
            if let state = matrixEditorMetadata() { result["matrixEditor"] = state }
        } else {
            result["ordinaryContinuationTextMatches"] = editor?.ordinaryContinuationTextMatches ?? false
            result["ordinaryContinuationSelectionMatches"] = editor?.ordinaryContinuationSelectionMatches ?? false
            result["ordinaryWakeReleaseObserved"] = editor?.ordinaryWakeReleaseObserved ?? false
        }
        return result
    }

    /// Только состояния fixture и штатного responder chain; action не выполняется.
    private func matrixEditorMetadata() -> [String: Bool]? {
        let application = NSApplication.shared
        guard let editor, let window, let item = matrixSelectItem,
              editor.matrixArmed, application.isActive, window.isKeyWindow,
              window.firstResponder === editor else { return nil }
        item.menu?.update()
        guard application.isActive, window.isKeyWindow, window.firstResponder === editor else { return nil }
        let target = application.target(forAction: #selector(NSText.selectAll(_:)), to: nil, from: item)
        return [
            "editable": editor.isEditable, "selectable": editor.isSelectable,
            "targetIsEditor": (target as AnyObject?) === editor, "menuEnabled": item.isEnabled
        ]
    }

    private func scheduleDeadline(maximumLifetime: TimeInterval) {
        timer?.invalidate()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000
        let timer = Timer(timeInterval: max(0.001, maximumLifetime - elapsed), target: self,
                          selector: #selector(timedOut), userInfo: nil, repeats: false)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func installMatrixMenu() {
        let menu = NSMenu()
        let application = NSMenuItem(title: "LSwitch", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "LSwitch")
        let quit = NSMenuItem(title: "Quit LSwitch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationMenu.addItem(quit)
        application.submenu = applicationMenu
        menu.addItem(application)
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        let select = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        select.keyEquivalentModifierMask = .command
        matrixSelectItem = select
        edit.addItem(select)
        item.submenu = edit
        menu.addItem(item)
        NSApplication.shared.mainMenu = menu
    }

    private func reply(_ kind: String, sequence: Int, includeTitle: Bool = false) {
        var fields = envelope(kind, sequence: sequence)
        if includeTitle { fields["windowTitle"] = window?.title }
        guard channel?.send(fields) == true else { return finish("protocol") }
    }

    private func envelope(_ kind: String, sequence: Int) -> [String: Any] {
        var fields = metadata()
        fields["v"] = 1
        fields["nonce"] = nonce
        fields["sequence"] = sequence
        fields["kind"] = kind
        fields["pid"] = getpid()
        fields["senderPID"] = senderPID
        return fields
    }

    private func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        stopSecureInput()
        exitStatus = reason == "quit" || reason == "eof" ? 0 : 1
        timer?.invalidate()
        timer = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        var fields = envelope("exiting", sequence: lastSequence)
        fields["reason"] = reason
        window?.delegate = nil
        window?.close()
        window = nil
        editor = nil
        fields["windowCleanupCompleted"] = true
        channel?.send(fields)
        channel?.stopInput()
        NSApplication.shared.stop(nil)
        if let wake = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
        ) {
            // Внутреннее пробуждение run(), не клавиатурный пакет и не ввод в редактор.
            NSApplication.shared.postEvent(wake, atStart: false)
        }
    }
}
#endif
