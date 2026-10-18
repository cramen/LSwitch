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
    let controlTextMatches: Bool
    let controlSelectionMatches: Bool
    let ordinaryContinuationTextMatches: Bool
    let ordinaryContinuationSelectionMatches: Bool
    let ordinaryWakeReleaseObserved: Bool
    let received: [String]
    let changeCount: Int?
    let foreignInput: Bool
    let overflow: Bool
    let active: Bool
    let focused: Bool
    let reason: String?
    let matrixArmed: Bool
    let matrixLocal: [String: Int]
    let matrixDispatch: [String: Int]
    let matrixShortcut: [String: Bool]
    let matrixEditor: [String: Bool]
    let secure: [String: Bool]
    let secureCounts: [String: Int]
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
    let controlTextMatches: Bool
    let controlSelectionMatches: Bool
    let ordinaryContinuationTextMatches: Bool?
    let ordinaryContinuationSelectionMatches: Bool?
    let ordinaryWakeReleaseObserved: Bool?
    let received: [String]
    let changeCount: Int
    let foreignInput: Bool
    let overflow: Bool
    let active: Bool
    let focused: Bool
    let reason: String?
    let matrixArmed: Bool?
    let matrixLocal: [String: Int]?
    let matrixDispatch: [String: Int]?
    let matrixShortcut: [String: Bool]?
    let matrixEditor: [String: Bool]?
    let secure: [String: Bool]?
    let secureCounts: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case nonce, sequence, kind, pid, senderPID, windowTitle, fixtureTextUnchanged, fixtureSelectionUnchanged
        case controlTextMatches, controlSelectionMatches
        case ordinaryContinuationTextMatches, ordinaryContinuationSelectionMatches
        case ordinaryWakeReleaseObserved
        case received, changeCount, foreignInput, overflow, active, focused, reason
        case matrixArmed, matrixLocal, matrixDispatch, matrixShortcut, matrixEditor, secure, secureCounts
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
        let kinds = ["ready", "configured", "selected", "matrix_armed", "snapshot", "exiting", "secure_input"]
        guard let reply = try? JSONDecoder().decode(IsolationChildWireReply.self, from: data),
              reply.version == 1, reply.nonce == nonce, reply.pid == target, reply.senderPID == sender,
              (0...32).contains(reply.sequence), reply.changeCount >= 0,
              kinds.contains(reply.kind),
              reply.received.count <= RecoveryIsolationWire.maximumObservations,
              reply.received.allSatisfy({ RecoveryIsolationLabel(rawValue: $0) != nil }),
              validMatrix(reply), validSecure(reply) else {
            return nil
        }
        let continuationText: Bool = reply.ordinaryContinuationTextMatches ?? false
        let continuationSelection: Bool = reply.ordinaryContinuationSelectionMatches ?? false
        let wakeRelease: Bool = reply.ordinaryWakeReleaseObserved ?? false
        let matrixArmed: Bool = reply.matrixArmed ?? false
        let matrixLocal: [String: Int] = reply.matrixLocal ?? [:]
        let matrixDispatch: [String: Int] = reply.matrixDispatch ?? [:]
        let matrixShortcut: [String: Bool] = reply.matrixShortcut ?? [:]
        let matrixEditor: [String: Bool] = reply.matrixEditor ?? [:]
        let secure: [String: Bool] = reply.secure ?? [:]
        let secureCounts: [String: Int] = reply.secureCounts ?? [:]
        return IsolationChildMessage(
            sequence: reply.sequence, kind: reply.kind, processID: target, windowTitle: reply.windowTitle,
            fixtureTextUnchanged: reply.fixtureTextUnchanged,
            fixtureSelectionUnchanged: reply.fixtureSelectionUnchanged,
            controlTextMatches: reply.controlTextMatches, controlSelectionMatches: reply.controlSelectionMatches,
            ordinaryContinuationTextMatches: continuationText,
            ordinaryContinuationSelectionMatches: continuationSelection,
            ordinaryWakeReleaseObserved: wakeRelease,
            received: reply.received, changeCount: reply.changeCount, foreignInput: reply.foreignInput,
            overflow: reply.overflow, active: reply.active, focused: reply.focused, reason: reply.reason,
            matrixArmed: matrixArmed, matrixLocal: matrixLocal,
            matrixDispatch: matrixDispatch, matrixShortcut: matrixShortcut, matrixEditor: matrixEditor,
            secure: secure, secureCounts: secureCounts
        )
    }

    private func validSecure(_ reply: IsolationChildWireReply) -> Bool {
        guard reply.secure != nil || reply.secureCounts != nil else { return reply.kind != "secure_input" }
        guard reply.matrixArmed != true, let secure = reply.secure, let counts = reply.secureCounts,
              Set(secure.keys) == ["enabled", "owned", "refused"], Set(counts.keys) == ["enable", "disable"],
              let enables = counts["enable"], let disables = counts["disable"],
              (0...1).contains(enables), (0...1).contains(disables), disables <= enables else { return false }
        return secure["owned"] != true || enables == 1
    }

    private func validMatrix(_ reply: IsolationChildWireReply) -> Bool {
        let local = reply.matrixLocal ?? [:]
        let dispatched = reply.matrixDispatch ?? [:]
        let shortcut = reply.matrixShortcut ?? [:]
        let editor = reply.matrixEditor ?? [:]
        guard RecoveryIsolationMatrixState.validCounts(local: local, dispatched: dispatched) else { return false }
        if !shortcut.isEmpty {
            guard Set(shortcut.keys) == ["observed", "command", "charactersA", "ignoringModifiersA"],
                  shortcut["observed"] == true else { return false }
        }
        if !editor.isEmpty {
            guard Set(editor.keys) == ["editable", "selectable", "targetIsEditor", "menuEnabled"],
                  reply.active, reply.focused else { return false }
        }
        if reply.matrixArmed == true { return true }
        return reply.kind != "matrix_armed" && local.isEmpty && dispatched.isEmpty
            && shortcut.isEmpty && editor.isEmpty
    }
}
#endif
