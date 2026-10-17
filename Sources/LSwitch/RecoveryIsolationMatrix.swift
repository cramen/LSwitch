#if DEBUG
import CoreGraphics
import Foundation

enum RecoveryIsolationMatrixFamily: String, CaseIterable, Sendable {
    case keyDown, keyUp, flagsChanged, mouseDown, mouseUp, mouseDrag, scroll
}

/// Только счётчики фиксированных семейств. Лимит общий для двух точек наблюдения.
struct RecoveryIsolationMatrixState {
    enum Stage { case local, dispatch }
    static let maximumObservations = 256
    private(set) var armed = false
    private(set) var local: [String: Int] = [:]
    private(set) var dispatched: [String: Int] = [:]
    private(set) var overflow = false
    private var total = 0

    mutating func arm() -> Bool {
        guard !armed else { return false }
        armed = true
        return true
    }

    mutating func record(_ family: RecoveryIsolationMatrixFamily, stage: Stage) {
        guard armed else { return }
        guard total < Self.maximumObservations else { overflow = true; return }
        total += 1
        switch stage {
        case .local: local[family.rawValue, default: 0] += 1
        case .dispatch: dispatched[family.rawValue, default: 0] += 1
        }
    }

    static func validCounts(local: [String: Int], dispatched: [String: Int]) -> Bool {
        let names = Set(RecoveryIsolationMatrixFamily.allCases.map(\.rawValue))
        let values = Array(local.values) + Array(dispatched.values)
        return Set(local.keys).isSubset(of: names) && Set(dispatched.keys).isSubset(of: names)
            && values.allSatisfy { $0 > 0 && $0 <= maximumObservations }
            && values.reduce(0, +) <= maximumObservations
    }
}

/// Единственный parent chord — left Command + A. Не читает Unicode и не выполняет команды.
enum RecoveryIsolationMatrixKeyboard {
    static func permits(
        label: RecoveryIsolationLabel, type: CGEventType, keyCode: Int64, flags: CGEventFlags
    ) -> Bool {
        let command = CGEventFlags.maskCommand.rawValue
        let stateless = CGEventFlags.maskNonCoalesced.rawValue
        let leftCommand: UInt64 = 0x00000008
        switch label {
        case .prefixDown:
            return type == .flagsChanged && keyCode == 55
                && matches(flags.rawValue, required: command, optional: stateless | leftCommand)
        case .prefixRelease:
            return type == .flagsChanged && keyCode == 55 && matches(flags.rawValue, required: 0, optional: stateless)
        case .challengeDown:
            return type == .keyDown && keyCode == 0
                && matches(flags.rawValue, required: command, optional: stateless | leftCommand)
        case .challengeRelease:
            return type == .keyUp && keyCode == 0
                && matches(flags.rawValue, required: command, optional: stateless | leftCommand)
        }
    }

    private static func matches(_ value: UInt64, required: UInt64, optional: UInt64) -> Bool {
        value & required == required && value & ~(required | optional) == 0
    }
}
#endif
