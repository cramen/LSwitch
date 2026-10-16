#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

/// Модель callback без CGEvent.post, tapCreate или запуска системного worker.
@MainActor
final class RecipientTapDriverFixture {
    let bridge: RecoveryRecipientProbeBridge
    let state: RecipientTapDriverState

    init(activate: Bool = true) throws {
        let bridge = try XCTUnwrap(RecoveryRecipientProbeBridge.makeOwnProcess())
        self.bridge = bridge
        state = RecipientTapDriverState(bridge: bridge)
        XCTAssertTrue(bridge.preparePair(keyCode: 0, downFlags: 0, releaseFlags: 0))
        state.recordInstallation(head: true, tail: true)
        if activate { XCTAssertTrue(bridge.activateProtection()) }
    }

    func event(isDown: Bool, owned: Bool = true) throws -> CGEvent {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown))
        event.flags = []
        let marker = owned ? try XCTUnwrap(bridge.marker(isDown: isDown)) : 0
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), marker)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUnixProcessID), Int64(bridge.senderProcessID))
        return event
    }
}
#endif
