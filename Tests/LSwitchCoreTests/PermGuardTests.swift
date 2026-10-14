@testable import LSwitchCore
import XCTest

final class PermGuardTests: XCTestCase {
    @MainActor
    func testRevocationAndRestorationCallbacksFollowActualTransitions() async {
        var status = PermGuard.Status(accessibility: true, inputMonitoring: true)
        let monitor = PermGuard(check: { status })
        var transitions: [String] = []
        monitor.onPermissionsLost = { _ in transitions.append("lost") }
        monitor.onPermissionsRestored = { transitions.append("restored") }
        monitor.onStatusChanged = { _ in transitions.append("changed") }
        monitor.checkNow()
        XCTAssertTrue(transitions.isEmpty)
        status = .init(accessibility: false, inputMonitoring: true)
        monitor.checkNow()
        monitor.checkNow()
        XCTAssertEqual(transitions, ["lost", "changed"])
        XCTAssertEqual(monitor.current, status)
        status = .init(accessibility: true, inputMonitoring: true)
        monitor.checkNow()
        monitor.checkNow()
        XCTAssertEqual(transitions, ["lost", "changed", "restored", "changed"])
    }

    @MainActor
    func testPartialGrantStillRequiresAccessAndDoesNotSignalRestoration() async {
        var status = PermGuard.Status(accessibility: false, inputMonitoring: false)
        let monitor = PermGuard(check: { status })
        var missing: [PermGuard.Status] = []
        var restored = 0
        monitor.onPermissionsLost = { missing.append($0) }
        monitor.onPermissionsRestored = { restored += 1 }
        status = .init(accessibility: true, inputMonitoring: false)
        monitor.checkNow()
        XCTAssertEqual(missing, [status])
        XCTAssertEqual(restored, 0)
        XCTAssertFalse(monitor.current.allGranted)
        status = .init(accessibility: false, inputMonitoring: true)
        monitor.checkNow()
        XCTAssertEqual(missing.count, 2)
        XCTAssertEqual(restored, 0)
    }

    @MainActor
    func testTimerCanStopAndRestartWithoutDuplicatePolling() async {
        var polls = 0
        let polled = expectation(description: "Таймер выполнил опрос")
        polled.assertForOverFulfill = false
        let monitor = PermGuard(checkInterval: 0.02, check: {
            polls += 1
            if polls > 1 { polled.fulfill() }
            return .init(accessibility: true, inputMonitoring: true)
        })
        monitor.start()
        monitor.start()
        await fulfillment(of: [polled], timeout: 1)
        monitor.stop()
        let stoppedPolls = polls
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(polls, stoppedPolls)
        monitor.start()
        try? await Task.sleep(nanoseconds: 80_000_000)
        monitor.stop()
        XCTAssertGreaterThan(polls, stoppedPolls)
    }
}
