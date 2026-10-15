import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

private final class RecordingSoundBackend: SoundFeedbackBackend, @unchecked Sendable {
    private typealias Completion = @Sendable () -> Void
    private let lock = NSLock()
    private var calls: [(name: String, onMain: Bool)] = []
    private var pending: [Completion] = []
    private let prepareGate: DispatchSemaphore?
    private let playGate: DispatchSemaphore?
    private let prepareStarted: XCTestExpectation?
    private let playStarted: XCTestExpectation?
    private let disposed: XCTestExpectation?
    private let succeeds: Bool
    private let completeImmediately: Bool

    init(
        prepareGate: DispatchSemaphore? = nil, playGate: DispatchSemaphore? = nil,
        prepareStarted: XCTestExpectation? = nil, playStarted: XCTestExpectation? = nil,
        disposed: XCTestExpectation? = nil, succeeds: Bool = true, completeImmediately: Bool = true
    ) {
        self.prepareGate = prepareGate
        self.playGate = playGate
        self.prepareStarted = prepareStarted
        self.playStarted = playStarted
        self.disposed = disposed
        self.succeeds = succeeds
        self.completeImmediately = completeImmediately
    }

    var steps: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls.map { $0.name }
    }

    var touchedMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return calls.contains { $0.onMain }
    }

    func record(_ name: String) {
        lock.lock()
        calls.append((name, Thread.isMainThread))
        lock.unlock()
    }

    func prepare() -> Bool {
        record("prepare")
        prepareStarted?.fulfill()
        if let prepareGate { XCTAssertEqual(prepareGate.wait(timeout: .now() + 3), .success) }
        return succeeds
    }

    func play(completion: @escaping @Sendable () -> Void) {
        record("play")
        playStarted?.fulfill()
        if let playGate { XCTAssertEqual(playGate.wait(timeout: .now() + 3), .success) }
        if completeImmediately {
            completion()
        } else {
            lock.lock()
            pending.append(completion)
            lock.unlock()
        }
    }

    func completePlayback() {
        lock.lock()
        let completion = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        completion?()
    }

    func dispose() {
        record("dispose")
        disposed?.fulfill()
    }
}

final class SoundFeedbackControllerTests: XCTestCase {
    private func controller(_ backend: RecordingSoundBackend) -> SoundFeedbackController {
        SoundFeedbackController(backendFactory: {
            backend.record("factory")
            return backend
        })
    }

    @MainActor
    func testPrepareCreatesResourceOnWorkerWithoutPlaying() async {
        let backend = RecordingSoundBackend()
        let subject = controller(backend)
        subject.setEnabled(true)
        subject.prepare()
        await subject.drainScheduledWork()
        XCTAssertEqual(backend.steps, ["factory", "prepare"])
        XCTAssertFalse(backend.touchedMain)
        subject.shutdown()
        await subject.drainScheduledWork()
        XCTAssertEqual(backend.steps, ["factory", "prepare", "dispose"])
    }

    @MainActor
    func testDisabledAndNonSuccessOutcomesNeverPlay() async {
        let backend = RecordingSoundBackend()
        let subject = controller(backend)
        subject.prepare()
        subject.handle(.converted(original: "ghbdtn", converted: "привет"))
        await subject.drainScheduledWork()
        XCTAssertTrue(backend.steps.isEmpty)
        subject.setEnabled(true)
        await subject.drainScheduledWork()
        let outcomes: [Converter.Outcome] = [
            .undone, .partiallyConverted(original: "ghbdtn", converted: "привет", targetLayout: .russian),
            .partiallyUndone(targetLayout: .english), .failed, .busy,
            .blockedByRules, .blockedBySafety, .unsupportedLayout
        ]
        for outcome in outcomes { subject.handle(outcome) }
        await subject.drainScheduledWork()
        XCTAssertEqual(backend.steps, ["factory", "prepare"])
        subject.shutdown()
        await subject.drainScheduledWork()
    }

    @MainActor
    func testBlockedPrepareDoesNotBlockMainAndOffCancelsWaitingPlay() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let began = expectation(description: "prepare работает на worker")
        let backend = RecordingSoundBackend(prepareGate: gate, prepareStarted: began)
        let subject = controller(backend)
        subject.setEnabled(true)
        await fulfillment(of: [began], timeout: 1)
        subject.conversionSucceeded()
        subject.setEnabled(false)
        let mainTurn = expectation(description: "main выполняется, пока prepare заблокирован")
        DispatchQueue.main.async { mainTurn.fulfill() }
        await fulfillment(of: [mainTurn], timeout: 1)
        gate.signal()
        await subject.drainScheduledWork()
        XCTAssertEqual(backend.steps, ["factory", "prepare", "dispose"])
        XCTAssertFalse(backend.touchedMain)
        subject.shutdown()
    }

    @MainActor
    func testBlockedPlayDoesNotBlockMainAndShutdownWaitsOffMain() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let began = expectation(description: "play работает на worker")
        let disposed = expectation(description: "ресурс освобождён после завершения попытки")
        let backend = RecordingSoundBackend(playGate: gate, playStarted: began, disposed: disposed)
        let subject = controller(backend)
        subject.setEnabled(true)
        await subject.drainScheduledWork()
        subject.conversionSucceeded()
        await fulfillment(of: [began], timeout: 1)
        subject.shutdown()
        let mainTurn = expectation(description: "main выполняется, пока play заблокирован")
        DispatchQueue.main.async { mainTurn.fulfill() }
        await fulfillment(of: [mainTurn], timeout: 1)
        XCTAssertFalse(backend.steps.contains("dispose"))
        gate.signal()
        await fulfillment(of: [disposed], timeout: 1)
        subject.shutdown()
        await subject.drainScheduledWork()
        XCTAssertEqual(backend.steps, ["factory", "prepare", "play", "dispose"])
        XCTAssertFalse(backend.touchedMain)
    }

    @MainActor
    func testInFlightAttemptRetainsResourceUntilCompletion() async {
        let began = expectation(description: "попытка принята")
        let disposed = expectation(description: "освобождение после callback")
        let backend = RecordingSoundBackend(playStarted: began, disposed: disposed, completeImmediately: false)
        let subject = controller(backend)
        subject.setEnabled(true)
        subject.conversionSucceeded()
        await fulfillment(of: [began], timeout: 1)
        await subject.drainScheduledWork()
        subject.shutdown()
        await subject.drainScheduledWork()
        XCTAssertFalse(backend.steps.contains("dispose"))
        backend.completePlayback()
        await fulfillment(of: [disposed], timeout: 1)
        XCTAssertEqual(backend.steps.filter { $0 == "dispose" }.count, 1)
        XCTAssertFalse(backend.touchedMain)
    }

    @MainActor
    func testDeinitDisposesPreparedResourceOnWorker() async {
        let disposed = expectation(description: "deinit не вызывает audio API на main")
        let backend = RecordingSoundBackend(disposed: disposed)
        var subject: SoundFeedbackController? = controller(backend)
        subject?.setEnabled(true)
        await subject?.drainScheduledWork()
        weak var released = subject
        subject = nil
        XCTAssertNil(released)
        await fulfillment(of: [disposed], timeout: 1)
        XCTAssertFalse(backend.touchedMain)
    }

    @MainActor
    func testPrepareFailureNeverCallsPlayAndStillDisposesBackend() async {
        let backend = RecordingSoundBackend(succeeds: false)
        let subject = controller(backend)
        subject.setEnabled(true)
        await subject.drainScheduledWork()
        subject.conversionSucceeded()
        await subject.drainScheduledWork()
        XCTAssertFalse(backend.steps.contains("play"))
        subject.shutdown()
        await subject.drainScheduledWork()
        XCTAssertEqual(backend.steps.filter { $0 == "dispose" }.count, 1)
    }

    @MainActor
    func testOldPlayIsNotReplayedAfterOffOnWhilePreparationIsBlocked() async {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let began = expectation(description: "prepare ожидает")
        let backend = RecordingSoundBackend(prepareGate: gate, prepareStarted: began)
        let subject = controller(backend)
        subject.setEnabled(true)
        await fulfillment(of: [began], timeout: 1)
        subject.conversionSucceeded()
        subject.setEnabled(false)
        subject.setEnabled(true)
        gate.signal()
        await subject.drainScheduledWork()
        XCTAssertFalse(backend.steps.contains("play"))
        subject.conversionSucceeded()
        await subject.drainScheduledWork()
        XCTAssertEqual(backend.steps.filter { $0 == "play" }.count, 1)
        subject.shutdown()
        await subject.drainScheduledWork()
    }
}
