import AppKit
import LSwitchCore

/// Отдельный DEBUG preview; штатный AppDelegate, перехват и запросы разрешений не запускаются.
@MainActor
enum RecoveryWindowPreview {
    static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.contains("--recovery-window-preview") else { return nil }
        #if DEBUG
        guard Bundle.main.bundleIdentifier == "ru.cramen.lswitch" else {
            print("{\"fixtureOnly\":true,\"status\":\"invalid_identity\"}")
            return 2
        }
        return RecoveryWindowPreviewDelegate().run()
        #else
        print("{\"fixtureOnly\":true,\"status\":\"debug_only\"}")
        return 2
        #endif
    }
}

#if DEBUG
@MainActor
private final class RecoveryWindowPreviewDelegate: NSObject, NSApplicationDelegate {
    private var fixture: RecoveryWindowPreviewFixture?
    private var controller: RecoveryWindowController?
    private var ownedWindows: [NSWindow] = []
    private var timer: Timer?
    private var finished = false
    private var status = "not_started"
    private var cleanupCompleted = false
    private var postedWakeEvent = false
    private var finalFixtureReport: RecoveryWindowPreviewReport?
    private let started = DispatchTime.now().uptimeNanoseconds

    func run() -> Int32 {
        // NSApplication создаётся до первого CGEvent/CGEventSource внутри fixture.
        let application = NSApplication.shared
        let previousDelegate = application.delegate
        let previousMenu = application.mainMenu
        let previousPolicy = application.activationPolicy()
        application.delegate = self
        _ = application.setActivationPolicy(.accessory)
        application.mainMenu = makeMenu()
        let timer = Timer(timeInterval: 120, target: self, selector: #selector(timeout), userInfo: nil, repeats: false)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        application.run()
        if !finished { finish("event_loop_stopped") }
        application.delegate = previousDelegate
        application.mainMenu = previousMenu
        _ = application.setActivationPolicy(previousPolicy)
        printReport()
        return cleanupCompleted && status != "setup_failed" ? 0 : 1
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let fixture = RecoveryWindowPreviewFixture.make() else { return finish("setup_failed") }
        self.fixture = fixture
        let before = Set(NSApplication.shared.windows.map { ObjectIdentifier($0) })
        let controller = RecoveryWindowController(session: RecoveryWindowSession())
        self.controller = controller
        controller.prepare()
        ownedWindows = NSApplication.shared.windows.filter { !before.contains(ObjectIdentifier($0)) }
        guard ownedWindows.count == 1 else { return finish("setup_failed") }
        status = "preview_ready"
        showPreview()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPreview()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finish("quit")
        return .terminateCancel
    }

    @objc private func showPreview() {
        guard !finished, let fixture, let controller else { return }
        fixture.show()
        guard let metadata = fixture.metadata else { return finish("setup_failed") }
        // Тот же session сохраняет drafts; show возвращает только metadata и скрытое содержимое.
        controller.show(metadata, actions: fixture.actions)
    }

    @objc private func timeout() { finish("timeout") }

    private func finish(_ result: String) {
        guard !finished else { return }
        finished = true
        status = result
        timer?.invalidate()
        timer = nil
        controller?.hide()
        finalFixtureReport = fixture?.report
        for window in ownedWindows {
            window.delegate = nil
            window.close()
        }
        cleanupCompleted = ownedWindows.allSatisfy { !$0.isVisible }
        ownedWindows.removeAll()
        controller = nil
        fixture = nil
        let application = NSApplication.shared
        application.stop(nil)
        if let wake = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
        ) {
            // Только внутренний applicationDefined wake для выхода из NSApplication.run, не ввод.
            postedWakeEvent = true
            application.postEvent(wake, atStart: false)
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let applicationItem = NSMenuItem(title: "LSwitch Preview", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "LSwitch Preview")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let reopen = NSMenuItem(
            title: "Показать окно восстановления", action: #selector(showPreview), keyEquivalent: "r"
        )
        reopen.target = self
        applicationMenu.addItem(reopen)
        applicationMenu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Завершить preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        quit.target = NSApplication.shared
        applicationMenu.addItem(quit)
        let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Правка")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        // Только стандартные ручные команды пользователя через responder chain; ничего не вызываем сами.
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return menu
    }

    private func printReport() {
        let value = finalFixtureReport
        let report: [String: Any] = [
            "fixtureOnly": true, "status": status, "protection": "unverified",
            "syntheticTarget": true, "fakeGate": true, "recoveryGateAccepted": false,
            "captureUsed": false, "cgEventsPosted": false, "appKitWakeEventPosted": postedWakeEvent,
            "requestedPermissions": false,
            "automaticClipboardAccess": false, "payloadLogged": false, "cleanupCompleted": cleanupCompleted,
            "timeoutSeconds": 120, "elapsedMs": (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000,
            "eventsAtExit": value?.eventCount ?? 0, "utf16BytesAtExit": value?.utf16Bytes ?? 0,
            "fixtureReferencesReleased": fixture == nil,
            "payloadDeletedByAction": value?.payloadDeleted ?? false,
            "revealCount": value?.revealCount ?? 0, "deletionRequests": value?.deletionRequests ?? 0,
            "confirmedDeletions": value?.confirmedDeletions ?? 0,
            "cancelledDeletions": value?.cancelledDeletions ?? 0,
            "hideCount": value?.hideCount ?? 0, "showCount": value?.showCount ?? 0
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
    }
}
#endif
