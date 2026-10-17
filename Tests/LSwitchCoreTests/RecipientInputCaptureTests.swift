#if DEBUG
import CoreGraphics
import Foundation
@testable import LSwitchCore
import XCTest

final class RecipientInputCaptureTests: XCTestCase {
    @MainActor
    func testUnregisteredStaticMagicFromAnotherSenderIsPreservedInsteadOfDroppedAsOwnInput() throws {
        let fixture = try RecipientInputCaptureFixture()
        let event = try fixture.event(.keyDown, marker: SyntheticEventMarker.magic)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 321)
        XCTAssertEqual(fixture.endpoint.route(type: .keyDown, event: event), .suppress)
        XCTAssertEqual(fixture.attachment.counters.capturedEvents, 1)
        XCTAssertEqual(fixture.attachment.counters.rejectedEvents, 0)
        let entries = try fixture.recover()
        XCTAssertEqual(entries.count, 1)
        guard case .unicodeFragment(let fragment) = entries[0].content else { return XCTFail("Потерян payload") }
        XCTAssertEqual(fragment.text, "kept")
    }

    @MainActor
    func testRecipientCapturePreservesOrderWithoutReadingUnicodeForMouseOrModifiers() throws {
        let fixture = try RecipientInputCaptureFixture()
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .scrollWheel, .keyUp]
        for type in types {
            XCTAssertEqual(fixture.endpoint.route(type: type, event: try fixture.event(type)), .suppress)
        }
        XCTAssertEqual(fixture.attachment.counters.capturedEvents, 5)
        XCTAssertEqual(fixture.attachment.counters.payloadCountReads, 2)
        XCTAssertEqual(fixture.attachment.counters.capturedUTF16Bytes, 16)
        let entries = try fixture.recover()
        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries.map(\.ordinal), [0, 1, 2, 3, 4])
        guard case .unicodeFragment(let fragment) = entries[0].content else { return XCTFail("Потерян текст") }
        XCTAssertEqual(fragment.text, "kept")
        XCTAssertEqual(entries[1].content, .nonText(.modifierChange))
        XCTAssertEqual(entries[2].content, .nonText(.mouse(button: .left, phase: .down)))
        XCTAssertEqual(entries[3].content, .unresolved(.unsupportedEvent))
        XCTAssertEqual(entries[4].content, .nonText(.keyRelease))
    }

    @MainActor
    func testOwnRegisteredHeaderBypassesCaptureBeforeAndAfterRetirement() throws {
        let fixture = try RecipientInputCaptureFixture()
        let own = try fixture.event(.keyDown, marker: 9901)
        XCTAssertEqual(fixture.endpoint.route(type: .keyDown, event: own), .passThrough)
        XCTAssertEqual(fixture.attachment.counters.payloadCountReads, 0)
        _ = try fixture.recover()
        XCTAssertEqual(fixture.endpoint.route(type: .keyDown, event: own), .passThrough)
        XCTAssertEqual(fixture.attachment.counters.capturedEvents, 0)
    }

    @MainActor
    func testRetirementSuppressesAllRecipientFamiliesWithoutExtendingPrivateRecord() throws {
        let fixture = try RecipientInputCaptureFixture()
        XCTAssertEqual(fixture.endpoint.route(type: .keyDown, event: try fixture.event(.keyDown)), .suppress)
        _ = try fixture.recover()
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseUp, .otherMouseDragged, .scrollWheel]
        for type in types {
            XCTAssertEqual(fixture.endpoint.route(type: type, event: try fixture.event(type)), .suppress)
        }
        XCTAssertEqual(fixture.attachment.counters.capturedEvents, 1)
        XCTAssertEqual(fixture.attachment.counters.payloadCountReads, 1)
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
    }

    @MainActor
    func testFixtureOnlyRouterRefusesGeneralRecipientPolicyBeforeBinding() throws {
        let fixture = try RecipientInputCaptureFixture(acceptsRecipientInput: false)
        XCTAssertFalse(fixture.router.attach(fixture.attachment))
        XCTAssertFalse(fixture.endpoint.bindRecipientInput(
            router: fixture.router, scope: fixture.operation.capturePort.scope.binding.scope
        ))
        XCTAssertEqual(fixture.endpoint.route(type: .keyDown, event: try fixture.event(.keyDown)), .passThrough)
        XCTAssertEqual(fixture.attachment.counters.payloadCountReads, 0)
    }

    @MainActor
    func testForeignScopeAndRepeatedBindingCannotRedirectRecipientCapture() throws {
        let fixture = try RecipientInputCaptureFixture()
        let other = try RecipientInputCaptureFixture()
        let endpoint = RecipientTapCaptureEndpoint()
        XCTAssertFalse(endpoint.bindRecipientInput(
            router: fixture.router, scope: other.operation.capturePort.scope.binding.scope
        ))
        XCTAssertTrue(endpoint.bindRecipientInput(
            router: fixture.router, scope: fixture.operation.capturePort.scope.binding.scope
        ))
        XCTAssertFalse(endpoint.bindRecipientInput(
            router: other.router, scope: other.operation.capturePort.scope.binding.scope
        ))
        XCTAssertEqual(endpoint.route(type: .keyDown, event: try fixture.event(.keyDown)), .suppress)
        XCTAssertEqual(fixture.attachment.counters.capturedEvents, 1)
        XCTAssertEqual(other.attachment.counters.capturedEvents, 0)
    }

    @MainActor
    func testLostGateRejectsRecipientInputBeforePayloadReadAndKeepsStoredPrefix() throws {
        let fixture = try RecipientInputCaptureFixture()
        XCTAssertEqual(fixture.endpoint.route(type: .keyDown, event: try fixture.event(.keyDown)), .suppress)
        fixture.gate.setAvailable(false)
        XCTAssertEqual(fixture.endpoint.route(type: .keyDown, event: try fixture.event(.keyDown)), .suppress)
        XCTAssertEqual(fixture.attachment.counters.payloadCountReads, 1)
        XCTAssertEqual(fixture.attachment.counters.capturedEvents, 1)
        XCTAssertEqual(try fixture.recover().count, 1)
    }
}

@MainActor
private final class RecipientInputCaptureFixture {
    let gate = RecoveryCaptureTestGate()
    let ledger = ConversionSafetyLedger(generation: 1)
    let endpoint = RecipientTapCaptureEndpoint()
    let router: RecoveryCaptureRouter
    let coordinator: RecoveryCoordinator
    let operation: RecoveryOperation
    let attachment: RecoveryCaptureAttachment

    init(acceptsRecipientInput: Bool = true) throws {
        let router = RecoveryCaptureRouter(bypassRawProcessing: true, acceptsRecipientInput: acceptsRecipientInput)
        self.router = router
        let gate = self.gate
        let coordinator = RecoveryCoordinator(gateFactory: .init(prepare: { scope in
            .init(scope: scope, isCurrent: { gate.isCurrent() })
        }))
        self.coordinator = coordinator
        let target = try XCTUnwrap(RecoveryProcessIdentity(processID: 123, birthSeconds: 1, birthMicroseconds: 2))
        let admission = try XCTUnwrap(coordinator.reserve(operation: ledger.operation, target: target))
        let operation = try XCTUnwrap(RecoveryOperation.prepare(
            ledger: ledger, admission: admission, tapIdentifier: router.identifier, at: 0,
            handoverFactory: .init(prepare: { gate.prepared($0, tap: $1) })
        ))
        self.operation = operation
        gate.bind(operation.capturePort.scope)
        attachment = RecoveryCaptureAttachment(port: operation.capturePort, policy: .recipientInput,
                                               ownMarker: { _, marker in marker == 9901 }, clock: { 1 })
        if acceptsRecipientInput {
            XCTAssertTrue(router.attach(attachment))
            XCTAssertTrue(endpoint.bindRecipientInput(router: router, scope: operation.capturePort.scope.binding.scope))
        }
    }

    func event(_ type: CGEventType, marker: Int64 = 8801) throws -> CGEvent {
        let event = try RecoveryOperationFixture.event("kept")
        event.type = type
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    func recover() throws -> [RecoveryProjectionEntry] {
        XCTAssertTrue(operation.closeCaptureForStorage(router: router, attachment: attachment))
        _ = ledger.finishUsingRecordedCleanup(operation: ledger.operation, text: .unknown, ordinaryRouteValid: false)
        guard case .adopted = operation.adopt(in: coordinator, reason: .cleanupUnconfirmed) else {
            throw NSError(domain: "RecipientInputCaptureFixture", code: 1)
        }
        XCTAssertTrue(coordinator.reveal(try XCTUnwrap(coordinator.requestReveal())))
        return try XCTUnwrap(coordinator.revealedProjection).entries
    }
}
#endif
