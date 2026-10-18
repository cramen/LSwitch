#if DEBUG
import CoreFoundation
import Foundation

enum RecoveryIsolationCommand: String, Sendable {
    case handshake, configure, selectFixture, armEventMatrix, snapshot, quit, secureInputOn, secureInputOff
}

enum RecoveryIsolationLabel: String, CaseIterable, Sendable {
    case prefixDown, prefixRelease, challengeDown, challengeRelease
}

struct RecoveryIsolationRequest: Sendable {
    let sequence: Int
    let command: RecoveryIsolationCommand
    let markers: [RecoveryIsolationLabel: Int64]?
}

/// Единственный вход — маленький JSON frame. Нет команд с текстом, путями или выполняемым содержимым.
enum RecoveryIsolationWire {
    static let maximumRequestBytes = 512
    static let maximumReplyBytes = 1024
    static let maximumRequests = 32
    static let maximumReplies = 34
    static let maximumObservations = 16

    static func decode(_ data: Data, nonce: String, expectedSequence: Int) -> RecoveryIsolationRequest? {
        guard !data.isEmpty, data.count < maximumRequestBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any], integer(fields["v"]) == 1,
              fields["nonce"] as? String == nonce,
              let sequence = integer(fields["sequence"]), sequence == Int64(expectedSequence),
              sequence > 0, sequence <= Int64(maximumRequests),
              let name = fields["command"] as? String,
              let command = RecoveryIsolationCommand(rawValue: name) else { return nil }
        let keys: Set<String> = ["v", "nonce", "sequence", "command"]
        if command == .configure {
            guard Set(fields.keys) == keys.union(["markers"]), let markers = decodeMarkers(fields["markers"]) else {
                return nil
            }
            return .init(sequence: Int(sequence), command: command, markers: markers)
        }
        guard Set(fields.keys) == keys else { return nil }
        return .init(sequence: Int(sequence), command: command, markers: nil)
    }

    static func encode(_ fields: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(fields),
              var data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              data.count < maximumReplyBytes else { return nil }
        data.append(10)
        return data
    }

    private static func decodeMarkers(_ value: Any?) -> [RecoveryIsolationLabel: Int64]? {
        guard let fields = value as? [String: Any],
              Set(fields.keys) == Set(RecoveryIsolationLabel.allCases.map(\.rawValue)) else { return nil }
        var result: [RecoveryIsolationLabel: Int64] = [:]
        for label in RecoveryIsolationLabel.allCases {
            guard let marker = integer(fields[label.rawValue]), marker > 0, marker < (1 << 52) else { return nil }
            result[label] = marker
        }
        guard Set(result.values).count == RecoveryIsolationLabel.allCases.count else { return nil }
        return result
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.int64Value
        return NSNumber(value: integer) == number ? integer : nil
    }
}
#endif
