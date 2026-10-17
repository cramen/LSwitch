import CoreGraphics
import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

final class EventProcessingLeaseTests: XCTestCase {
    func testActualTapSubscriptionMaskIncludesScrollAndEveryLeaseEventFamily() {
        let expected: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel
        ]
        for type in expected {
            XCTAssertNotEqual(EventTapCore.subscribedEventMask & (CGEventMask(1) << type.rawValue), 0)
        }
        XCTAssertEqual(EventTapCore.subscribedEventMask & (CGEventMask(1) << CGEventType.mouseMoved.rawValue), 0)
    }

    func testSubscribedScrollDoesNotEnterLegacyHoldOrRawDecoder() throws {
        let buffer = InputEventBuffer()
        XCTAssertNotNil(buffer.beginHold(at: 0))
        let event = try EventProcessingTestFixture.event("unread", type: .scrollWheel)
        XCTAssertFalse(buffer.intercept(type: .scrollWheel, event: event, at: 1))
        XCTAssertNil(EventTapCore.makeRawEvent(type: .scrollWheel, event: event))
        buffer.end { _ in XCTFail("Legacy scroll не удерживается и не replay-ится") }
    }

    func testActivityBeforeArmInvalidatesPreparationWithoutReadingPayload() throws {
        let state = EventProcessingLeaseState()
        let lease = try XCTUnwrap(state.begin(scope: EventProcessingTestFixture.scope(), at: 1))
        XCTAssertTrue(state.preCaptureReady(lease, at: 2))
        XCTAssertTrue(state.observe(type: .keyDown, event: try EventProcessingTestFixture.event(), at: 3))
        XCTAssertFalse(state.preCaptureReady(lease, at: 4))
        XCTAssertFalse(state.arm(lease, at: 4))
        XCTAssertEqual(state.metadata.activity, 1)
        XCTAssertEqual(state.metadata.failure, .inputBeforeCapture)
        XCTAssertEqual(state.metadata.payloadReads, 0)
        XCTAssertEqual(state.metadata.eventCount, 0)
    }

    func testEpochAndStateIdentityRejectForeignAndPreviouslyFinishedLease() throws {
        let state = EventProcessingLeaseState()
        let other = EventProcessingLeaseState()
        let scope = try EventProcessingTestFixture.scope()
        let lease = try XCTUnwrap(state.begin(scope: scope, at: 1))
        let foreign = try XCTUnwrap(other.begin(scope: scope, at: 1))
        XCTAssertFalse(state.arm(foreign, at: 2))
        XCTAssertFalse(state.claimFinish(foreign, disposition: .discard, at: 2))
        XCTAssertTrue(state.claimFinish(lease, disposition: .discard, at: 2))
        guard case .finished(.discarded) = state.next(lease, at: 2) else { return XCTFail("Нужен discard") }
        let next = try XCTUnwrap(state.begin(scope: scope, at: 3))
        XCTAssertNotEqual(next, lease)
        XCTAssertFalse(state.arm(lease, at: 3))
        XCTAssertFalse(state.claimFinish(lease, disposition: .discard, at: 3))
        XCTAssertTrue(state.preCaptureReady(next, at: 3))
    }

    func testExpiryClearsOnlyLogicalBacklogAndStopsNewPayloadReads() throws {
        let state = EventProcessingLeaseState()
        let lease = try XCTUnwrap(state.begin(scope: EventProcessingTestFixture.scope(), at: 1))
        XCTAssertTrue(state.arm(lease, at: 1))
        XCTAssertTrue(state.observe(type: .keyDown, event: try EventProcessingTestFixture.event(), at: 2))
        XCTAssertEqual(state.metadata.payloadReads, 1)
        state.expire(lease, at: 400_000_001)
        XCTAssertFalse(state.isCurrent(lease, at: 400_000_001))
        XCTAssertTrue(state.observe(type: .keyDown, event: try EventProcessingTestFixture.event(), at: 400_000_002))
        XCTAssertEqual(state.metadata.eventCount, 0)
        XCTAssertEqual(state.metadata.payloadReads, 1)
        XCTAssertEqual(state.metadata.failure, .expired)
    }

    func testEventQuotaStopsBeforeReadingExcessEventAndNeverPublishesTruncatedTail() throws {
        let state = EventProcessingLeaseState(eventLimit: 2)
        let lease = try XCTUnwrap(state.begin(scope: EventProcessingTestFixture.scope(), at: 1))
        XCTAssertTrue(state.arm(lease, at: 1))
        for _ in 0..<3 {
            XCTAssertTrue(state.observe(type: .keyDown, event: try EventProcessingTestFixture.event(), at: 2))
        }
        XCTAssertEqual(state.metadata.failure, .eventLimit)
        XCTAssertEqual(state.metadata.payloadReads, 2)
        XCTAssertEqual(state.metadata.eventCount, 0)
        XCTAssertTrue(state.claimFinish(lease, disposition: .delivered(nil), at: 3))
        guard case .finished(.reset(.eventLimit)) = state.next(lease, at: 3) else {
            return XCTFail("Усечённый хвост не разрешён")
        }
    }

    func testPayloadQuotaIsLogicalUTF16AndRefusesWholeTail() throws {
        let state = EventProcessingLeaseState(byteLimit: 4)
        let lease = try XCTUnwrap(state.begin(scope: EventProcessingTestFixture.scope(), at: 1))
        XCTAssertTrue(state.arm(lease, at: 1))
        XCTAssertTrue(state.observe(type: .keyDown, event: try EventProcessingTestFixture.event("😀"), at: 2))
        XCTAssertEqual(state.metadata.utf16Bytes, 4)
        XCTAssertTrue(state.observe(type: .keyDown, event: try EventProcessingTestFixture.event("a"), at: 2))
        XCTAssertEqual(state.metadata.failure, .payloadLimit)
        XCTAssertEqual(state.metadata.eventCount, 0)
        XCTAssertEqual(state.metadata.utf16Bytes, 0)
    }

    func testMalformedCallbackTypeCannotReadPayloadOrPublishTail() throws {
        let state = EventProcessingLeaseState()
        let lease = try XCTUnwrap(state.begin(scope: EventProcessingTestFixture.scope(), at: 1))
        XCTAssertTrue(state.arm(lease, at: 1))
        let event = try EventProcessingTestFixture.event("a", type: .flagsChanged)
        XCTAssertTrue(state.observe(type: .keyDown, event: event, at: 2))
        XCTAssertEqual(state.metadata.failure, .invalidPayload)
        XCTAssertEqual(state.metadata.eventCount, 0)
        XCTAssertEqual(state.metadata.payloadReads, 0)
    }

    func testStrictUTF16RejectsSurrogatesAndInconsistentCountsWithoutNormalization() {
        XCTAssertNil(EventProcessingRawReader.decode([0xD800], expected: 1, actual: 1, rechecked: 1))
        XCTAssertNil(EventProcessingRawReader.decode([0xDC00], expected: 1, actual: 1, rechecked: 1))
        XCTAssertNil(EventProcessingRawReader.decode([97], expected: 1, actual: 0, rechecked: 1))
        XCTAssertNil(EventProcessingRawReader.decode([97], expected: 1, actual: 1, rechecked: 2))
        let exact: [UInt16] = [101, 0x301, 0xA0, 0xD83D, 0xDE00]
        let decoded = EventProcessingRawReader.decode(exact, expected: 5, actual: 5, rechecked: 5)
        XCTAssertEqual(decoded.map { Array($0.utf16) }, exact)
    }

    func testFocusStopAndPermissionLossNeverReadSubsequentPayload() throws {
        for reason: EventProcessingInvalidation in [.focusChanged, .stopped, .permissionLost] {
            let state = EventProcessingLeaseState()
            let lease = try XCTUnwrap(state.begin(scope: EventProcessingTestFixture.scope(), at: 1))
            XCTAssertTrue(state.arm(lease, at: 1))
            XCTAssertTrue(state.observe(type: .keyDown, event: try EventProcessingTestFixture.event(), at: 2))
            state.invalidate(reason)
            XCTAssertTrue(state.observe(type: .keyDown, event: try EventProcessingTestFixture.event(), at: 3))
            XCTAssertEqual(state.metadata.failure, reason)
            XCTAssertEqual(state.metadata.payloadReads, 1)
            XCTAssertEqual(state.metadata.eventCount, 0)
        }
    }

    func testModifiersReleasesAndMouseDoNotReadUnicodeAndKeepTheirOrder() throws {
        let state = EventProcessingLeaseState()
        let lease = try XCTUnwrap(state.begin(scope: EventProcessingTestFixture.scope(), at: 1))
        XCTAssertTrue(state.arm(lease, at: 1))
        for type: CGEventType in [.flagsChanged, .keyUp, .leftMouseDown, .scrollWheel] {
            XCTAssertTrue(state.observe(type: type, event: try EventProcessingTestFixture.event("secret", type: type),
                                        at: 2))
        }
        XCTAssertEqual(state.metadata.payloadReads, 0)
        XCTAssertEqual(state.metadata.utf16Bytes, 0)
        XCTAssertTrue(state.claimFinish(lease, disposition: .delivered(nil), at: 2))
        for expected: RawKeyEventType in [.flagsChanged, .keyUp, .other, .other] {
            guard case .event(let raw) = state.next(lease, at: 2) else { return XCTFail("Потерян порядок") }
            XCTAssertEqual(raw.type, expected)
            XCTAssertTrue(raw.characters.isEmpty)
        }
    }

    func testTrackedLogicalTailPreservesUnknownFlagsWithoutApplyingLegacyCorrection() throws {
        let state = EventProcessingLeaseState()
        let lease = try XCTUnwrap(state.begin(scope: EventProcessingTestFixture.scope(), at: 100))
        XCTAssertTrue(state.arm(lease, at: 100))
        let event = try EventProcessingTestFixture.event("ц")
        event.timestamp = 150
        event.flags = CGEventFlags(rawValue: 0x2000_0000)
        XCTAssertTrue(state.observe(type: .keyDown, event: event, at: 150))
        let correction = QueuedInputCorrection(from: .russian, to: .english, startedAt: 100, completedAt: 200)
        XCTAssertTrue(state.claimFinish(lease, disposition: .delivered(correction), at: 200))
        guard case .event(let raw) = state.next(lease, at: 200) else { return XCTFail("Потерян logical tail") }
        XCTAssertEqual(raw.characters, "ц")
        XCTAssertEqual(raw.modifierFlags, 0x2000_0000)
        XCTAssertEqual(correction.corrected(raw).characters, "w", "Legacy путь намеренно остаётся прежним")
    }
}
