import AppKit
import CoreGraphics

/// Ранний dispatcher для уже подписанного LSwitch.app; штатный AppDelegate не нужен.
@MainActor
enum RecoveryReceiverProbe {
    static func runIfRequested(arguments: [String]) -> Int32? {
        let prefix = "--recovery-receiver-probe="
        guard let argument = arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        #if DEBUG
        guard Bundle.main.bundleIdentifier == "ru.cramen.lswitch",
              let scenario = RecoveryReceiverProbeScenario(rawValue: String(argument.dropFirst(prefix.count))) else {
            print("{\"status\":\"invalid_identity_or_scenario\",\"recoveryGateAccepted\":false}")
            return 2
        }
        return RecoveryReceiverProbeController(scenario: scenario).run()
        #else
        print("{\"status\":\"debug_only\",\"recoveryGateAccepted\":false}")
        return 2
        #endif
    }
}

#if DEBUG
private enum RecoveryReceiverProbeScenario: String {
    case baseline
    case lateBeforeAdmission = "late-before-admission"
    case lateAfterAdmission = "late-after-admission"
    case balanceAfterClose = "balance-after-close"
    case disableFailOpen = "disable-fail-open"
}

@MainActor
private final class RecoveryReceiverProbeController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let scenario: RecoveryReceiverProbeScenario
    private let gate: RecoveryReceiverProbeGate
    private let title = "LSwitch Recovery Receiver Probe \(UUID().uuidString)"
    private let fixture = "seed "
    private let started = DispatchTime.now().uptimeNanoseconds
    private var window: NSWindow?
    private var editor: RecoveryReceiverProbeView?
    private var timer: Timer?
    private var status = "not_started"
    private var posted: [String] = []
    private var submittedAt: UInt64?
    private var firstCompleteAt: UInt64?
    private var closedAfterSubmission = false
    private var closedAfterAdmission = false
    private var closedAfterReceiverDown = false
    private var tailPairBeforeClosure = false
    private var receiverEmptyAtClosure = false
    private var fixtureIntactAtClosure = false
    private var admissionWaitNanoseconds: UInt64 = 0
    private var eventSource: CGEventSource?
    private var finished = false
    private var observed = false
    private var textMatches = false
    private var selectionMatches = false
    private var receiverObserved: [String] = []
    private var cleanupCompleted = false
    private var textChangeCount = 0
    private var gateBeforeCleanup: RecoveryReceiverProbeGate.Snapshot?

    init(scenario: RecoveryReceiverProbeScenario) {
        self.scenario = scenario
        let balancing = scenario == .balanceAfterClose || scenario == .lateBeforeAdmission
        gate = RecoveryReceiverProbeGate(allowsPairedUpAfterClose: balancing)
    }

    func run() -> Int32 {
        // Создание NSApplication подготавливает process event source до own-PID taps.
        let application = NSApplication.shared
        guard CGPreflightListenEventAccess(), CGPreflightPostEventAccess() else {
            status = "permissions_unavailable"
            cleanupCompleted = true
            return report()
        }
        guard gate.start() else {
            status = "gate_unavailable"
            cleanupCompleted = gate.stop()
            return report()
        }
        let priorDelegate = application.delegate
        let priorPolicy = application.activationPolicy()
        application.delegate = self
        _ = application.setActivationPolicy(.accessory)
        let timer = Timer(timeInterval: 0.02, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        application.run()
        if !finished { finish("event_loop_stopped") }
        application.delegate = priorDelegate
        _ = application.setActivationPolicy(priorPolicy)
        return report()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 560, height: 180)
        let editor = RecoveryReceiverProbeView(frame: frame)
        editor.isRichText = false
        editor.allowsUndo = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.string = fixture
        editor.setSelectedRange(NSRange(location: fixture.utf16.count, length: 0))
        editor.identify = { [gate] event in event.cgEvent.flatMap { gate.eventLabel($0) } }
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.delegate = self
        self.window = window
        self.editor = editor
        window.center()
        window.makeKeyAndOrderFront(nil)
        _ = window.makeFirstResponder(editor)
        NSApplication.shared.activate(ignoringOtherApps: true)
        status = "waiting_for_own_focus"
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finish("operator_quit")
        return .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        finish("operator_closed_window")
        return false
    }

    @objc private func tick() {
        guard !finished else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - started < 4_250_000_000 else { return finish("scenario_timeout") }
        guard let editor else { return }
        if editor.foreignInputObserved || editor.observationOverflow { return finish("unexpected_input") }
        if submittedAt == nil {
            guard hasOwnFocus else { return }
            submitInitialInput()
            return
        }
        guard hasOwnFocus else { return finish("focus_lost") }
        observeReceiver(editor, now: now)
    }

    private func observeReceiver(_ editor: RecoveryReceiverProbeView, now: UInt64) {
        let state = gate.snapshot()
        guard state.failure == nil, state.tailEnabled else { return finish("gate_lost") }
        let expectedHead = scenario != .disableFailOpen
        guard state.headEnabled == expectedHead else { return finish("unexpected_head_state") }
        let expectedText = scenario == .lateBeforeAdmission ? fixture : fixture + "a"
        let expectedRange = NSRange(location: expectedText.utf16.count, length: 0)
        textMatches = editor.string.utf16.elementsEqual(expectedText.utf16)
        selectionMatches = editor.selectedRange() == expectedRange
        if scenario == .balanceAfterClose, posted == ["down"] {
            balanceAfterReceiverDown(editor, state: state)
            return
        }
        guard routingMatches(state, editor: editor), textMatches, selectionMatches else {
            firstCompleteAt = nil
            return
        }
        if firstCompleteAt == nil { firstCompleteAt = now }
        guard let firstCompleteAt, now - firstCompleteAt >= 150_000_000 else { return }
        observed = true
        finish(observedStatus)
    }

    private func routingMatches(
        _ state: RecoveryReceiverProbeGate.Snapshot, editor: RecoveryReceiverProbeView
    ) -> Bool {
        let pair = ["down", "up"]
        let deliveredPair = state.admitted == pair && state.blocked.isEmpty && state.tail == pair
            && editor.received == pair
        switch scenario {
        case .baseline:
            return deliveredPair
        case .lateBeforeAdmission:
            return state.blocked == pair && state.admitted.isEmpty && state.tail.isEmpty
                && editor.received.isEmpty && closedAfterSubmission
        case .lateAfterAdmission:
            return deliveredPair && closedAfterAdmission
        case .balanceAfterClose:
            return deliveredPair && closedAfterReceiverDown && state.balancedUpCount == 1
        case .disableFailOpen:
            return state.admitted.isEmpty && state.blocked.isEmpty && state.tail == pair
                && editor.received == pair
        }
    }

    private var observedStatus: String {
        switch scenario {
        case .disableFailOpen: return "disable_fail_open_observed"
        case .lateAfterAdmission: return "late_execution_after_generation_close_observed"
        case .balanceAfterClose: return "paired_up_after_generation_close_observed"
        case .baseline, .lateBeforeAdmission: return "own_receiver_observed"
        }
    }

    private var hasOwnFocus: Bool {
        guard let window, let editor else { return false }
        let application = NSApplication.shared
        return application.isActive && application.keyWindow === window && window.isKeyWindow
            && window.title == title && window.firstResponder === editor
    }

    private func finish(_ result: String) {
        guard !finished else { return }
        finished = true
        status = result
        timer?.invalidate()
        timer = nil
        receiverObserved = editor?.received ?? []
        textChangeCount = editor?.textChangeCount ?? 0
        gateBeforeCleanup = gate.snapshot()
        cleanupCompleted = gate.stop()
        window?.delegate = nil
        window?.close()
        window = nil
        editor = nil
        let application = NSApplication.shared
        application.stop(nil)
        if let wake = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
        ) {
            application.postEvent(wake, atStart: false)
        }
    }

    private func report() -> Int32 {
        let state = gateBeforeCleanup ?? gate.snapshot()
        let report: [String: Any] = [
            "scenario": scenario.rawValue, "status": status, "observationComplete": observed,
            "ownPIDOnly": true, "ownNSTextViewOnly": true, "posted": posted,
            "admitted": state.admitted, "blocked": state.blocked, "tailObserved": state.tail,
            "receiverObserved": receiverObserved, "textMatches": textMatches,
            "selectionMatches": selectionMatches, "textChangeCount": textChangeCount,
            "closedAfterSubmissionBeforeAdmission": closedAfterSubmission,
            "closedAfterAdmissionBeforeReceiver": closedAfterAdmission,
            "lateExecutionLimitationObserved": scenario == .lateAfterAdmission && observed,
            "tailPairBeforeClosure": tailPairBeforeClosure, "receiverEmptyAtClosure": receiverEmptyAtClosure,
            "fixtureIntactAtClosure": fixtureIntactAtClosure,
            "closedAfterReceiverDown": closedAfterReceiverDown, "balancedUpCount": state.balancedUpCount,
            "admissionWaitBudgetMs": 100, "admissionWaitNanoseconds": admissionWaitNanoseconds,
            "headEnabledBeforeCleanup": state.headEnabled, "tailEnabledBeforeCleanup": state.tailEnabled,
            "disableNotifications": state.disableNotifications, "cleanupCompleted": cleanupCompleted,
            "gateFailure": state.failure ?? "none", "absenceObservationIsBounded": true,
            "scenarioBudgetMs": 4_250,
            "elapsedMs": (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
            "requestedPermissions": false, "clipboardTouched": false, "payloadLogged": false,
            "externalRendererAcknowledged": false, "recoveryGateAccepted": false, "safetyPassed": false
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let encoded = String(data: data, encoding: .utf8) {
            print(encoded)
        }
        // В fail-open успешен только опыт, а не безопасность; это явно разделено в JSON.
        return observed && cleanupCompleted ? 0 : 1
    }
}

private extension RecoveryReceiverProbeController {
    func submitInitialInput() {
        guard let source = CGEventSource(stateID: .privateState) else { return finish("event_source_failed") }
        eventSource = source
        if scenario == .disableFailOpen {
            gate.closeGeneration()
            guard gate.disableHead() else { return finish("head_disable_failed") }
        }
        submittedAt = DispatchTime.now().uptimeNanoseconds
        guard postKey(isDown: true) else { return }
        if scenario != .balanceAfterClose, !postKey(isDown: false) { return }
        if scenario == .lateBeforeAdmission {
            gate.closeGeneration()
            closedAfterSubmission = true
        }
        gate.releaseAdmissions()
        if scenario == .lateAfterAdmission { closeAfterTailAdmission() }
    }

    func postKey(isDown: Bool) -> Bool {
        guard hasOwnFocus else {
            finish("post_focus_guard")
            return false
        }
        let state = gate.snapshot()
        guard state.failure == nil, state.tailEnabled,
              state.headEnabled == (scenario != .disableFailOpen) else {
            finish("post_gate_guard")
            return false
        }
        guard let source = eventSource,
              let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else {
            finish("event_creation_failed")
            return false
        }
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: gate.markerBase + (isDown ? 0 : 1))
        if isDown {
            var character: UniChar = 97
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
        }
        posted.append(isDown ? "down" : "up")
        event.postToPid(getpid())
        return true
    }

    func closeAfterTailAdmission() {
        let waitingStarted = DispatchTime.now().uptimeNanoseconds
        let arrived = gate.waitForTailPair()
        admissionWaitNanoseconds = DispatchTime.now().uptimeNanoseconds - waitingStarted
        let state = gate.snapshot()
        tailPairBeforeClosure = arrived && state.admitted == ["down", "up"] && state.tail == ["down", "up"]
        receiverEmptyAtClosure = editor?.received.isEmpty == true
        fixtureIntactAtClosure = editor?.string.utf16.elementsEqual(fixture.utf16) == true
        // Никакого AppKit/RunLoop pump между post и закрытием поколения.
        gate.closeGeneration()
        closedAfterAdmission = tailPairBeforeClosure && receiverEmptyAtClosure && fixtureIntactAtClosure
        if !closedAfterAdmission { finish("late_admission_boundary_unconfirmed") }
    }

    func balanceAfterReceiverDown(
        _ editor: RecoveryReceiverProbeView, state: RecoveryReceiverProbeGate.Snapshot
    ) {
        guard state.admitted == ["down"], state.tail == ["down"], editor.received == ["down"],
              textMatches, selectionMatches else { return }
        gate.closeGeneration()
        closedAfterReceiverDown = true
        _ = postKey(isDown: false)
    }
}
#endif
