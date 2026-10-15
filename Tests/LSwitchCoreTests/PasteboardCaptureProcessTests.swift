import Foundation
@testable import LSwitchCore
import XCTest

final class PasteboardCaptureProcessTests: XCTestCase {
    @MainActor
    func testEOFDoesNotCompleteUntilOfficialTerminationCallback() async throws {
        let fixture = try helperFixture(afterWrite: "exec 1>&-\nsleep 0.04\nexit 0")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let worker = captureWorker(executable: fixture)
        let started = ContinuousClock.now
        let result = await worker.capture(named: "private-fixture")
        XCTAssertEqual(result, expected)
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(30))
    }

    @MainActor
    func testTerminationBeforePipeEOFStillWaitsForCompleteReply() async throws {
        let fixture = try helperFixture(beforeWrite: "(sleep 0.04) &", afterWrite: "exit 0")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let worker = captureWorker(executable: fixture)
        let started = ContinuousClock.now
        let result = await worker.capture(named: "private-fixture")
        XCTAssertEqual(result, expected)
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .milliseconds(30))
    }

    @MainActor
    func testNonzeroExitRejectsOtherwiseValidReply() async throws {
        let fixture = try helperFixture(afterWrite: "exit 7")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let worker = captureWorker(executable: fixture)
        let result = await worker.capture(named: "private-fixture")
        XCTAssertEqual(result, .unavailable)
        let next = await worker.capture(named: "private-fixture")
        XCTAssertEqual(next, .unavailable, "Завершённый helper должен освободить single-flight gate")
    }

    @MainActor
    private func captureWorker(executable: URL) -> PasteboardCaptureWorker {
        PasteboardCaptureWorker(timeout: 2, start: { name, started, completion in
            let process = PasteboardCaptureProcess()
            process.start(named: name, executable: executable, started: started, completion: completion)
            return { process.cancel() }
        })
    }

    private var expected: PasteboardCaptureResult {
        .captured(PasteboardSnapshot(items: [.init(dataByType: ["text": Data("fixture".utf8)])]), changeCount: 1)
    }

    private func helperFixture(beforeWrite: String = "", afterWrite: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("private-capture-fixture.sh")
        let reply = PasteboardCaptureReply(
            snapshot: PasteboardSnapshot(items: [.init(dataByType: ["text": Data("fixture".utf8)])]),
            changeCountBefore: 1, changeCountAfter: 1
        )
        let data = try JSONEncoder().encode(reply)
        let payload = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\n\(beforeWrite)\nprintf '%s' '\(payload)'\n\(afterWrite)\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}
