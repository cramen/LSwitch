#if DEBUG
import Foundation

/// Только фиксированные метаданные собственного child; строки редактора протокол не содержит.
struct IsolationChildMessage: Sendable {
    let sequence: Int
    let kind: String
    let processID: Int32
    let windowTitle: String?
    let fixtureTextUnchanged: Bool?
    let fixtureSelectionUnchanged: Bool?
    let received: [String]
    let changeCount: Int?
    let foreignInput: Bool
    let overflow: Bool
    let active: Bool
    let focused: Bool
    let reason: String?
}

struct IsolationChildMailboxSnapshot: Sendable {
    let messages: [IsolationChildMessage]
    let failure: String?
    let eof: Bool
    let exitStatus: Int32?
    let stderrBytes: Int
}

private struct IsolationChildWireReply: Decodable {
    let version: Int
    let nonce: String
    let sequence: Int
    let kind: String
    let pid: Int32
    let senderPID: Int32
    let windowTitle: String?
    let fixtureTextUnchanged: Bool
    let fixtureSelectionUnchanged: Bool
    let received: [String]
    let changeCount: Int
    let foreignInput: Bool
    let overflow: Bool
    let active: Bool
    let focused: Bool
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case nonce, sequence, kind, pid, senderPID, windowTitle, fixtureTextUnchanged, fixtureSelectionUnchanged
        case received, changeCount, foreignInput, overflow, active, focused, reason
    }
}

final class RecoveryIsolationChildMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let nonce: String
    private let sender: Int32
    private let target: Int32
    private var frame = Data()
    private var messages: [IsolationChildMessage] = []
    private var receivedCount = 0
    private var failure: String?
    private var eof = false
    private var exitStatus: Int32?
    private var stderrBytes = 0

    init(nonce: String, sender: Int32, target: Int32) {
        self.nonce = nonce
        self.sender = sender
        self.target = target
    }

    func ingest(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil, !eof else { return }
        for byte in data {
            if byte == 10 {
                guard receivedCount < RecoveryIsolationWire.maximumReplies,
                      let message = decode(frame) else { failure = "child_protocol"; return }
                messages.append(message)
                receivedCount += 1
                frame.removeAll(keepingCapacity: true)
            } else {
                guard frame.count < RecoveryIsolationWire.maximumReplyBytes - 1 else {
                    failure = "child_frame_limit"
                    return
                }
                frame.append(byte)
            }
        }
    }

    func recordEOF() {
        lock.lock()
        if !frame.isEmpty { failure = failure ?? "child_partial_frame" }
        frame.removeAll()
        eof = true
        lock.unlock()
    }

    func recordExit(_ status: Int32) {
        lock.lock()
        exitStatus = status
        lock.unlock()
    }

    func recordFailure(_ value: String) {
        lock.lock()
        failure = failure ?? value
        lock.unlock()
    }

    func recordStderr(bytes: Int) {
        lock.lock()
        stderrBytes = min(4097, stderrBytes + bytes)
        if stderrBytes > 4096 { failure = failure ?? "child_stderr_limit" }
        lock.unlock()
    }

    func take() -> IsolationChildMailboxSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = IsolationChildMailboxSnapshot(messages: messages, failure: failure, eof: eof,
                                                     exitStatus: exitStatus, stderrBytes: stderrBytes)
        messages.removeAll(keepingCapacity: true)
        return snapshot
    }

    private func decode(_ data: Data) -> IsolationChildMessage? {
        guard let reply = try? JSONDecoder().decode(IsolationChildWireReply.self, from: data),
              reply.version == 1, reply.nonce == nonce, reply.pid == target, reply.senderPID == sender,
              (0...32).contains(reply.sequence), reply.changeCount >= 0,
              ["ready", "configured", "selected", "snapshot", "exiting"].contains(reply.kind),
              reply.received.count <= RecoveryIsolationWire.maximumObservations,
              reply.received.allSatisfy({ RecoveryIsolationLabel(rawValue: $0) != nil }) else { return nil }
        return .init(
            sequence: reply.sequence, kind: reply.kind, processID: target, windowTitle: reply.windowTitle,
            fixtureTextUnchanged: reply.fixtureTextUnchanged,
            fixtureSelectionUnchanged: reply.fixtureSelectionUnchanged,
            received: reply.received, changeCount: reply.changeCount, foreignInput: reply.foreignInput,
            overflow: reply.overflow, active: reply.active, focused: reply.focused, reason: reply.reason
        )
    }
}
#endif
