import CoreGraphics
import Foundation

/// Только явно выбранная диагностика: один keyUp с nonce, без keyDown и пользовательского текста.
enum AcceptanceEventTapProbe {
    private final class Counter {
        let nonce: Int64
        var received = 0

        init(nonce: Int64) { self.nonce = nonce }
    }

    static func run() -> [String: Any] {
        let nonce = Int64.random(in: 1...Int64.max)
        let counter = Counter(nonce: nonce)
        let mask = CGEventMask(1) << CGEventType.keyUp.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                if type == .keyUp, let context {
                    let state = Unmanaged<Counter>.fromOpaque(context).takeUnretainedValue()
                    if event.getIntegerValueField(.eventSourceUserData) == state.nonce {
                        state.received += 1
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(counter).toOpaque()
        ) else {
            return ["ok": false, "tapCreated": false, "received": 0]
        }
        guard let runSource = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return ["ok": false, "tapCreated": true, "error": "run-loop-source"]
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
        defer {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runSource, .commonModes)
            CFMachPortInvalidate(tap)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        guard let source = CGEventSource(stateID: .privateState) else {
            return ["ok": false, "tapCreated": true, "error": "event-source"]
        }
        source.userData = nonce
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false),
              event.type == .keyUp, event.getIntegerValueField(.eventSourceUserData) == nonce else {
            return ["ok": false, "tapCreated": true, "error": "keyup-nonce"]
        }
        event.flags = []
        event.post(tap: .cghidEventTap)
        let deadline = Date().addingTimeInterval(2)
        while counter.received == 0 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return [
            "ok": counter.received == 1, "tapCreated": true, "received": counter.received,
            "eventType": "keyUp", "nonce": String(nonce), "postedKeyDown": false
        ]
    }
}
