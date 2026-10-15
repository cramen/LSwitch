import Foundation
@testable import LSwitchCore
import XCTest

final class PasteboardCaptureWorkerTests: XCTestCase {
    @MainActor
    func testBlockedReadTimesOutWithoutStartingAnotherHelperAndIgnoresLateReply() async {
        let reader = BlockingCaptureReader()
        let worker = PasteboardCaptureWorker(timeout: 0.02, start: reader.start)
        let result = await worker.capture(named: "test.board")
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(reader.cancellations, 1)
        let busy = await worker.capture(named: "test.board")
        XCTAssertEqual(busy, .busy)
        XCTAssertEqual(reader.starts, 1)
        reader.release()
        await reader.waitForCompletion()
        reader.blocks = false
        reader.reply = reply(count: 9)
        let next = await worker.capture(named: "test.board")
        XCTAssertEqual(next, .captured(reader.reply.snapshot, changeCount: 9))
        XCTAssertEqual(reader.starts, 2)
    }

    @MainActor
    func testCancellationReturnsBeforeBlockedReaderAndKeepsSingleFlight() async {
        let reader = BlockingCaptureReader()
        let worker = PasteboardCaptureWorker(timeout: 1, start: reader.start)
        let task = Task { await worker.capture(named: "test.board") }
        while reader.starts == 0 { await Task.yield() }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        let busy = await worker.capture(named: "test.board")
        XCTAssertEqual(busy, .busy)
        XCTAssertEqual(reader.cancellations, 1)
        reader.release()
        await reader.waitForCompletion()
    }

    @MainActor
    func testVersionChangeDuringCaptureAndInvalidReplyAreRejected() async {
        let snapshot = reply(count: 1).snapshot
        let changed = PasteboardCaptureReply(snapshot: snapshot, changeCountBefore: 1, changeCountAfter: 2)
        for result in [changed, nil] {
            let worker = PasteboardCaptureWorker(start: { _, _, complete in complete(result); return {} })
            let captured = await worker.capture(named: "test.board")
            XCTAssertEqual(captured, result == nil ? .unavailable : .changed)
        }
    }

    @MainActor
    func testCaptureTimeoutReleasesConverterHoldWithoutAnyClipboardOrTextMutation() async {
        let reader = BlockingCaptureReader()
        let worker = PasteboardCaptureWorker(timeout: 0.02, start: reader.start)
        let editor = ClipboardEditor(text: "ghbdtn ")
        editor.captureOverride = { await worker.capture(named: "test.board") }
        let fixture = ConverterFixture()
        fixture.axEngine.handler = { request in await editor.converter().perform(request) }
        let result = await fixture.converter.trigger(expectedWord: "ghbdtn", trailingText: " ", allowUndo: false)
        XCTAssertEqual(result, .blockedBySafety)
        XCTAssertEqual(fixture.actions, ["hold", "release"])
        XCTAssertFalse(fixture.holdActive)
        XCTAssertEqual(editor.writes, 0)
        XCTAssertEqual(editor.restores, 0)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
        XCTAssertTrue(editor.commands.isEmpty)
        XCTAssertEqual(editor.text, "ghbdtn ")
        editor.updateClipboard("new user copy")
        reader.release()
        await reader.waitForCompletion()
        XCTAssertEqual(editor.clipboard, "new user copy")
        XCTAssertEqual(editor.restores, 0)
        XCTAssertEqual(editor.writes, 0)
    }

    @MainActor
    func testForeignCopyDuringAsyncCaptureIsNotReplacedOrRestored() async {
        let editor = ClipboardEditor(text: "ghbdtn ")
        let captured = reply(count: editor.count)
        editor.captureOverride = {
            await Task.yield()
            editor.updateClipboard("new user copy")
            return .captured(captured.snapshot, changeCount: captured.changeCountAfter)
        }
        let result = await editor.converter().perform(ConversionRequest(
            expectedWord: "ghbdtn", trailingText: " ", useSelection: false
        ))
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.clipboard, "new user copy")
        XCTAssertEqual(editor.writes, 0)
        XCTAssertEqual(editor.restores, 0)
        XCTAssertTrue(editor.rangeWrites.isEmpty)
    }

    func testWireRoundTripPreservesNilEmptyDataAndMultipleItems() throws {
        let snapshot = PasteboardSnapshot(items: [
            .init(dataByType: ["text": Data("fixture".utf8), "missing": nil, "empty": Data()]),
            .init(dataByType: ["bytes": Data([0, 1, 2, 255])])
        ])
        let timing = PasteboardHelperTiming(mainEntered: 10, boardOpened: 20, captureFinished: 30, encodingStarted: 40)
        let value = PasteboardCaptureReply(
            snapshot: snapshot, changeCountBefore: 3, changeCountAfter: 3, timing: timing
        )
        let decoded = try JSONDecoder().decode(PasteboardCaptureReply.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.snapshot, snapshot)
        XCTAssertEqual(decoded.changeCountBefore, 3)
        XCTAssertEqual(decoded.changeCountAfter, 3)
        XCTAssertEqual(decoded.timing, timing)
    }

    private func reply(count: Int) -> PasteboardCaptureReply {
        PasteboardCaptureReply(
            snapshot: PasteboardSnapshot(items: [.init(dataByType: ["text": Data("fixture".utf8)])]),
            changeCountBefore: count, changeCountAfter: count
        )
    }
}

@MainActor
private final class BlockingCaptureReader {
    var starts = 0
    var cancellations = 0
    var blocks = true
    var reply = PasteboardCaptureReply(
        snapshot: PasteboardSnapshot(items: [.init(dataByType: ["text": Data("old fixture".utf8)])]),
        changeCountBefore: 0, changeCountAfter: 0
    )
    private let gate = DispatchSemaphore(value: 0)
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    func start(
        _ name: String, started: @escaping PasteboardCaptureWorker.Started,
        completion: @escaping PasteboardCaptureWorker.Completion
    ) -> () -> Void {
        starts += 1
        started()
        guard blocks else { completion(reply); return {} }
        let result = reply
        let gate = self.gate
        DispatchQueue.global().async {
            gate.wait()
            DispatchQueue.main.async {
                completion(result)
                self.finished = true
                self.waiter?.resume()
                self.waiter = nil
            }
        }
        return { self.cancellations += 1 }
    }

    func release() { gate.signal() }

    func waitForCompletion() async {
        guard !finished else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
