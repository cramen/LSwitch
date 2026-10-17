import CoreGraphics
import Foundation

/// Отдельный pure App-harness: без NSApplication, CGEvent, окон, tap или отправки событий.
@main
enum RecoveryIsolationMatrixChecks {
    enum Failure: Error { case failed(String) }
    static let nonce = "00000000-0000-0000-0000-000000000123"

    static func main() throws {
        try keyboardShapes()
        try boundedCounters()
        try validWireAndDefaults()
        try invalidMatrixWire()
        try editorMetadata()
        try ordinaryContinuationMetadata()
        try armRequestHasNoPayload()
        print("RecoveryIsolationMatrixChecks: 7 groups passed; no UI/events/clipboard")
    }

    static func require(_ value: Bool, _ name: String) throws {
        if !value { throw Failure.failed(name) }
    }

    static func keyboardShapes() throws {
        let labels = RecoveryIsolationLabel.allCases
        let types: [CGEventType] = [.flagsChanged, .flagsChanged, .keyDown, .keyUp]
        let codes: [Int64] = [55, 55, 0, 0]
        let modifiers: [CGEventFlags] = [.maskCommand, [], .maskCommand, .maskCommand]
        for index in labels.indices {
            let accepts = RecoveryIsolationMatrixKeyboard.permits
            try require(accepts(labels[index], types[index], codes[index], modifiers[index]), "correct shape")
            try require(!accepts(labels[index], .mouseMoved, codes[index], modifiers[index]), "wrong type")
            try require(!accepts(labels[index], types[index], 7, modifiers[index]), "wrong key")
            try require(!accepts(labels[index], types[index], codes[index], .maskShift), "wrong modifier")
            let stateless = modifiers[index].union(.maskNonCoalesced)
            try require(accepts(labels[index], types[index], codes[index], stateless), "stateless flag")
            let unknown = CGEventFlags(rawValue: modifiers[index].rawValue | 0x02000000)
            try require(!accepts(labels[index], types[index], codes[index], unknown), "unknown flag")
        }
    }

    static func boundedCounters() throws {
        var state = RecoveryIsolationMatrixState()
        state.record(.keyDown, stage: .local)
        try require(state.local.isEmpty, "unarmed counter")
        try require(state.arm(), "first arm")
        try require(!state.arm(), "rearm refused")
        for index in 0..<RecoveryIsolationMatrixState.maximumObservations {
            state.record(.mouseDrag, stage: index.isMultiple(of: 2) ? .local : .dispatch)
        }
        try require(!state.overflow, "exact budget")
        try require(state.local["mouseDrag"] == 128 && state.dispatched["mouseDrag"] == 128, "separate counters")
        state.record(.mouseUp, stage: .local)
        try require(state.overflow && state.local["mouseUp"] == nil, "overflow reported without growing")
        try require(RecoveryIsolationMatrixState.validCounts(local: state.local, dispatched: state.dispatched),
                    "bounded overflow metadata")
    }

    static func validWireAndDefaults() throws {
        let old = try decode(envelope())
        try require(!old.matrixArmed && old.matrixLocal.isEmpty && old.matrixDispatch.isEmpty, "old defaults")
        var fields = envelope(kind: "matrix_armed")
        fields["matrixArmed"] = true
        let armed = try decode(fields)
        try require(armed.matrixArmed && armed.matrixLocal.isEmpty, "initial armed maps")
        let counts = Dictionary(uniqueKeysWithValues: RecoveryIsolationMatrixFamily.allCases.map { ($0.rawValue, 18) })
        fields["matrixLocal"] = counts
        fields["matrixDispatch"] = counts
        fields["matrixShortcut"] = ["observed": true, "command": false, "charactersA": false,
                                    "ignoringModifiersA": false]
        fields["matrixEditor"] = ["editable": false, "selectable": false, "targetIsEditor": false,
                                  "menuEnabled": false]
        fields["windowTitle"] = "LSwitch Isolation Receiver \(nonce)"
        fields["windowCleanupCompleted"] = true
        fields["reason"] = "observation_overflow"
        let frame = try requireFrame(fields)
        try require(frame.count <= RecoveryIsolationWire.maximumReplyBytes, "max metadata frame")
        let result = try decode(fields)
        try require(result.matrixLocal == counts && result.matrixDispatch == counts, "matrix maps")
        try require(result.matrixShortcut["observed"] == true, "bounded shortcut metadata")
        try require(result.matrixEditor["menuEnabled"] == false, "bounded editor metadata")
    }

    static func invalidMatrixWire() throws {
        let bad: [[String: Any]] = [
            ["keyDown": -1], ["keyDown": 0], ["keyDown": 257], ["keyDown": Int.max],
            ["keyDown": true], ["keyDown": 1.5], ["unexpected": 1]
        ]
        for counts in bad {
            var fields = envelope()
            fields["matrixArmed"] = true
            fields["matrixLocal"] = counts
            try require(rejected(fields), "bad count or family")
        }
        var fields = envelope()
        fields["matrixLocal"] = ["keyDown": 1]
        try require(rejected(fields), "counts without arm")
        fields["matrixArmed"] = true
        fields["matrixLocal"] = ["keyDown": 128]
        fields["matrixDispatch"] = ["keyDown": 129]
        try require(rejected(fields), "combined budget")
        try require(rejected(envelope(kind: "matrix_armed")), "armed kind requires flag")
        fields = envelope()
        fields["matrixArmed"] = true
        fields["matrixShortcut"] = ["observed": true, "text": "forbidden"]
        try require(rejected(fields), "shortcut metadata must never contain text")
    }

    static func armRequestHasNoPayload() throws {
        var fields: [String: Any] = ["v": 1, "nonce": nonce, "sequence": 2, "command": "armEventMatrix"]
        let data = try JSONSerialization.data(withJSONObject: fields)
        try require(RecoveryIsolationWire.decode(data, nonce: nonce, expectedSequence: 2)?.command == .armEventMatrix,
                    "arm request")
        fields["text"] = "forbidden"
        let extra = try JSONSerialization.data(withJSONObject: fields)
        try require(RecoveryIsolationWire.decode(extra, nonce: nonce, expectedSequence: 2) == nil, "extra payload")
    }

    static func editorMetadata() throws {
        var fields = envelope()
        fields["matrixArmed"] = true
        let editor = ["editable": true, "selectable": false, "targetIsEditor": false, "menuEnabled": true]
        fields["matrixEditor"] = editor
        try require(try decode(fields).matrixEditor == editor, "exact editor boolean map")
        fields["focused"] = false
        try require(rejected(fields), "editor target metadata requires focus")
        fields["focused"] = true
        fields["active"] = false
        try require(rejected(fields), "editor target metadata requires active app")
        fields["active"] = true
        fields["matrixArmed"] = false
        try require(rejected(fields), "editor metadata requires arm")
        fields["matrixArmed"] = true
        fields["matrixEditor"] = ["editable": true, "selectable": true, "targetIsEditor": true]
        try require(rejected(fields), "editor map cannot be partial")
        fields["matrixEditor"] = ["editable": true, "selectable": true, "targetIsEditor": true,
                                  "menuEnabled": true, "unexpected": false]
        try require(rejected(fields), "editor map rejects unknown field")
        fields["matrixEditor"] = ["editable": "forbidden"]
        try require(rejected(fields), "editor metadata cannot contain text")
    }

    static func envelope(kind: String = "snapshot") -> [String: Any] {
        ["v": 1, "nonce": nonce, "sequence": 1, "kind": kind, "pid": Int32.max, "senderPID": Int32.max - 1,
         "fixtureTextUnchanged": true, "fixtureSelectionUnchanged": false, "controlTextMatches": false,
         "controlSelectionMatches": false, "received": [], "changeCount": 0, "foreignInput": false,
         "overflow": false, "active": true, "focused": true]
    }

    static func ordinaryContinuationMetadata() throws {
        let old = try decode(envelope())
        try require(!old.ordinaryContinuationTextMatches && !old.ordinaryContinuationSelectionMatches
                    && !old.ordinaryWakeReleaseObserved,
                    "missing continuation fields default false")
        var fields = envelope()
        fields["ordinaryContinuationTextMatches"] = true
        fields["ordinaryContinuationSelectionMatches"] = false
        fields["ordinaryWakeReleaseObserved"] = true
        let first = try decode(fields)
        try require(first.ordinaryContinuationTextMatches && !first.ordinaryContinuationSelectionMatches
                    && first.ordinaryWakeReleaseObserved,
                    "independent exact-state booleans")
        fields["ordinaryContinuationTextMatches"] = false
        fields["ordinaryContinuationSelectionMatches"] = true
        let second = try decode(fields)
        try require(!second.ordinaryContinuationTextMatches && second.ordinaryContinuationSelectionMatches,
                    "selection does not imply text match")
        fields["ordinaryContinuationSelectionMatches"] = false
        fields["ordinaryWakeReleaseObserved"] = false
        fields["sequence"] = RecoveryIsolationWire.maximumRequests
        fields["received"] = Array(repeating: "challengeRelease", count: RecoveryIsolationWire.maximumObservations)
        fields["changeCount"] = 256
        fields["windowTitle"] = "LSwitch Isolation Receiver \(nonce)"
        fields["windowCleanupCompleted"] = true
        fields["reason"] = "observation_overflow"
        try require(try requireFrame(fields).count <= RecoveryIsolationWire.maximumReplyBytes,
                    "bounded ordinary continuation frame")
        _ = try decode(fields)
        let invalidValues: [Any] = ["true", 0, 1, [String](), ["payload": "forbidden"]]
        let booleanFields = ["ordinaryContinuationTextMatches", "ordinaryContinuationSelectionMatches",
                             "ordinaryWakeReleaseObserved"]
        for field in booleanFields {
            for invalid in invalidValues {
                var malformed = envelope()
                malformed[field] = invalid
                try require(rejected(malformed), "continuation fields require booleans")
            }
        }
    }

    static func requireFrame(_ fields: [String: Any]) throws -> Data {
        guard let data = RecoveryIsolationWire.encode(fields) else { throw Failure.failed("frame encoding") }
        return data
    }

    static func decode(_ fields: [String: Any]) throws -> IsolationChildMessage {
        let mailbox = RecoveryIsolationChildMailbox(nonce: nonce, sender: Int32.max - 1, target: Int32.max)
        mailbox.ingest(try requireFrame(fields))
        let snapshot = mailbox.take()
        guard snapshot.failure == nil, let result = snapshot.messages.first else { throw Failure.failed("wire decode") }
        return result
    }

    static func rejected(_ fields: [String: Any]) -> Bool {
        do { _ = try decode(fields); return false } catch { return true }
    }
}
