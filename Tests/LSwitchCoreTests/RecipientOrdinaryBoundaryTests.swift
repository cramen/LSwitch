#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class RecipientOrdinaryBoundaryTests: XCTestCase {
    @MainActor
    func testIdleCaptureExpiresBeforeClaimWithoutRelyingOnAnotherInputOrTimer() throws {
        let fixture = try RecipientOrdinaryFixture(deadline: 800_000_000)
        fixture.clock.set(400_000_000)
        XCTAssertFalse(fixture.capture.isCurrent)
        let result = fixture.flush.accept(correction: nil, claimOwnership: {
            XCTFail("Истёкший scope не принимает claim")
            return nil
        }, postWake: { _ in XCTFail("Истёкший scope не отправляет control"); return true })
        guard case .refused = result else { return XCTFail("Ожидается отказ до claim") }
        XCTAssertEqual(fixture.ledger.inputOwner, .transaction)
    }

    @MainActor
    func testDelayedWakeCannotExtendOriginalHoldDeadline() throws {
        let fixture = try RecipientOrdinaryFixture(deadline: 800_000_000)
        try fixture.enqueue("kept")
        fixture.clock.set(399_000_000)
        try fixture.accept()
        fixture.clock.set(400_000_000)
        try fixture.deliver { _ in XCTFail("Новый transport deadline не продлевает исходный hold") }
        XCTAssertEqual(try fixture.retainedText(), ["kept"])
        XCTAssertEqual(fixture.flush.terminalProof?.progress.attemptedPosts, 0)
    }

    @MainActor
    func testDeviceOnlyShortcutModifiersDoNotChangeNativeCopiedUnicode() throws {
        let transition = ConversionRecoveryLayoutTransition(source: .russian, target: .english,
                                                            startedAt: 5, completedAt: 15)
        for bit: UInt64 in [0x01, 0x08, 0x10, 0x20, 0x40, 0x2000] {
            let event = try RecoveryOperationFixture.event("цщкдв")
            event.timestamp = 10
            event.flags = CGEventFlags(rawValue: bit)
            XCTAssertEqual(event.flags.rawValue, bit, "Fixture обязан сохранить проверяемый device bit")
            XCTAssertTrue(RecipientOrdinaryCorrection.prepare(event, transition: transition))
            XCTAssertEqual(OrdinaryCustodyFixture.text(event), "цщкдв")
        }
    }

    @MainActor
    func testUnsupportedModifierNeedingCorrectionRefusesEntireBatchBeforeFirstPost() throws {
        let fixture = try RecipientOrdinaryFixture()
        try fixture.enqueue("plain")
        let event = try RecoveryOperationFixture.event("цщкдв")
        event.timestamp = 10
        event.flags = CGEventFlags(rawValue: 0x2000_0000)
        XCTAssertEqual(event.flags.rawValue, 0x2000_0000)
        XCTAssertFalse(fixture.state.observe(type: .keyDown, event: event, isHead: true))
        try fixture.accept(correction: .init(source: .russian, target: .english, startedAt: 5, completedAt: 15))
        try fixture.deliver { _ in XCTFail("Все копии проверяются до первого post") }
        XCTAssertEqual(fixture.flush.terminalProof?.progress.attemptedPosts, 0)
        XCTAssertEqual(fixture.flush.terminalProof?.progress.failure, .copyUnavailable)
        XCTAssertEqual(try fixture.retainedText(), ["plain"])
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 2)
        let entries = try XCTUnwrap(fixture.coordinator.revealedProjection?.entries)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].ordinal, 1)
        XCTAssertEqual(entries[1].content, .unresolved(.unsupportedModifiers),
                       "Неизвестный modifier не превращается в выдуманный текст при reveal")
    }

    @MainActor
    func testOrdinaryRouteDoesNotReopenOldReservedNativePackets() throws {
        let fixture = try RecipientOrdinaryFixture()
        XCTAssertTrue(fixture.bridge.preparePair(keyCode: 0, downFlags: 0, releaseFlags: 0))
        let marker = try XCTUnwrap(fixture.bridge.marker(isDown: true))
        try fixture.accept()
        try fixture.deliver()
        let late = try RecoveryOperationFixture.event("late")
        late.setIntegerValueField(.eventSourceUserData, value: marker)
        XCTAssertFalse(fixture.state.observe(type: .keyDown, event: late, isHead: true))
        XCTAssertTrue(fixture.state.observe(type: .keyDown, event: try RecoveryOperationFixture.event("next"),
                                             isHead: true))
    }
}
#endif
