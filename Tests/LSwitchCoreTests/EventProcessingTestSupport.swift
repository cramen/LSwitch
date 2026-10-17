import CoreGraphics
import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

final class EventProcessingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1
    func read() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance(to value: UInt64) { lock.lock(); self.value = value; lock.unlock() }
}

enum EventProcessingTestFixture {
    static func scope() throws -> RecoveryOperationTarget {
        .init(operation: ConversionSafetyOperationToken(generation: 1),
              target: try XCTUnwrap(RecoveryProcessIdentity(processID: 123, birthSeconds: 1, birthMicroseconds: 2)))
    }

    static func event(_ text: String = "a", type: CGEventType = .keyDown) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: type == .keyDown))
        event.type = type
        event.flags = []
        event.timestamp = 10
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        let units = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        return event
    }
}

@MainActor
final class EventProcessingTrace {
    var entries: [String] = []
    var buffered = "old"
    var actions: EventProcessingActions {
        .init(applyOutcome: { self.entries.append("outcome"); self.buffered = "" },
              reset: { self.entries.append("reset"); self.buffered = "" },
              consume: { self.entries.append($0.characters); self.buffered += $0.characters })
    }
}
