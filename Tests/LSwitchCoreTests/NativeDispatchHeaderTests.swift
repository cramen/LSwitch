import CoreGraphics
import Darwin
import Dispatch
import Foundation
@testable import LSwitchCore
import XCTest

final class NativeDispatchHeaderTests: XCTestCase {
    #if DEBUG
    @MainActor
    func testDiagnosticUserPrefixHasSeparateNamespaceFromOwnCommands() throws {
        let fixture = try XCTUnwrap(RecoveryIsolationSession.allocateFixtureMarkers())
        XCTAssertFalse(NativeDispatchHeader.matches(sender: Int64(getpid()), marker: fixture.prefixDown))
        XCTAssertFalse(NativeDispatchHeader.matches(sender: Int64(getpid()), marker: fixture.prefixRelease))
    }
    #endif

    func testRecognitionRequiresActualReservationAndExactNamespace() throws {
        let markers = try XCTUnwrap(NativeDispatchMarkers(serialLimit: 3))
        let other = try XCTUnwrap(NativeDispatchMarkers())
        let first = try XCTUnwrap(markers.reserve(1)?.first)
        XCTAssertTrue(markers.containsReserved(first))
        XCTAssertFalse(markers.containsReserved(first + 1))
        XCTAssertFalse(markers.containsReserved(first - 1))
        XCTAssertFalse(markers.containsReserved(-1))
        XCTAssertFalse(markers.containsReserved(try XCTUnwrap(other.reserve(1)?.first)))
        XCTAssertNil(markers.reserve(3))
        XCTAssertFalse(markers.containsReserved(first + 1), "Отказ не выделяет частичный batch")
        XCTAssertEqual(markers.reserve(2), [first + 1, first + 2])
        XCTAssertTrue(markers.containsReserved(first + 2))
        XCTAssertFalse(markers.containsReserved(first + 3))
    }

    func testClosedRegistryMarkerRemainsRecognizedWithoutImplyingAdmission() throws {
        let scope = try EventProcessingTestFixture.scope()
        let registry = try XCTUnwrap(NativeDispatchRegistry(scope: scope))
        let shape = NativeDispatchPairShape(
            down: .init(phase: .keyDown, keyCode: 0, modifierFlags: 0),
            release: .init(phase: .keyUp, keyCode: 0, modifierFlags: 0))
        let pair = try XCTUnwrap(registry.reservePairs([shape])?.first)
        registry.closeGeneration()
        XCTAssertTrue(NativeDispatchHeader.matches(sender: Int64(getpid()), marker: pair.down.marker))
        XCTAssertEqual(registry.observe(marker: pair.down.marker, shape: shape.down, target: scope.target),
                       .rejected(.notSubmitted))
    }

    func testForeignSenderAndOtherAllocatorCannotBorrowOwnHeaderExemption() throws {
        let own = try XCTUnwrap(NativeDispatchMarkers.shared?.reserve(1)?.first)
        let other = try XCTUnwrap(NativeDispatchMarkers())
        XCTAssertTrue(NativeDispatchHeader.matches(sender: Int64(getpid()), marker: own))
        XCTAssertFalse(NativeDispatchHeader.matches(sender: Int64(getpid()) + 1, marker: own))
        XCTAssertFalse(NativeDispatchHeader.matches(sender: 0, marker: own))
        XCTAssertFalse(NativeDispatchHeader.matches(sender: Int64(getpid()),
                                                     marker: try XCTUnwrap(other.reserve(1)?.first)))
    }

    func testOwnPacketDoesNotInvalidatePreArmOrReadLogicalPayload() throws {
        let tap = EventTapCore(handler: { _ in XCTFail("Own command не является raw input") })
        let state = tap.processingLeases.state
        let now = DispatchTime.now().uptimeNanoseconds
        let lease = try XCTUnwrap(state.begin(scope: EventProcessingTestFixture.scope(), at: now))
        let event = try ownEvent()
        XCTAssertNotNil(tap.handleTapEvent(type: .keyDown, event: event))
        XCTAssertEqual(state.metadata.activity, 0)
        XCTAssertEqual(state.metadata.payloadReads, 0)
        XCTAssertTrue(state.preCaptureReady(lease, at: DispatchTime.now().uptimeNanoseconds))
    }

    func testOwnPacketBypassesActiveLogicalLeaseButUnknownMarkerStillEntersIt() throws {
        let tap = EventTapCore(handler: { _ in XCTFail("Lease должен удерживать logical tail") })
        let state = tap.processingLeases.state
        let now = DispatchTime.now().uptimeNanoseconds
        let lease = try XCTUnwrap(state.begin(scope: EventProcessingTestFixture.scope(), at: now))
        XCTAssertTrue(state.arm(lease, at: now))
        let event = try ownEvent()
        XCTAssertNotNil(tap.handleTapEvent(type: .keyDown, event: event))
        XCTAssertEqual(state.metadata.eventCount, 0)
        XCTAssertEqual(state.metadata.payloadReads, 0)
        let unknown = try eventWithMarker(0)
        XCTAssertFalse(NativeDispatchHeader.isOwnReservedEvent(unknown))
        XCTAssertNotNil(tap.handleTapEvent(type: .keyDown, event: unknown))
        XCTAssertEqual(state.metadata.eventCount, 1)
        XCTAssertEqual(state.metadata.payloadReads, 1)
        XCTAssertEqual(state.metadata.activity, 1)
    }

    private func ownEvent() throws -> CGEvent {
        let marker = try XCTUnwrap(NativeDispatchMarkers.shared?.reserve(1)?.first)
        let event = try eventWithMarker(marker)
        XCTAssertTrue(NativeDispatchHeader.isOwnReservedEvent(event))
        return event
    }

    private func eventWithMarker(_ marker: Int64) throws -> CGEvent {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        source.userData = marker
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.keyboardSetUnicodeString(stringLength: 1, unicodeString: Array("x".utf16))
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUnixProcessID), Int64(getpid()))
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), marker)
        return event
    }
}
