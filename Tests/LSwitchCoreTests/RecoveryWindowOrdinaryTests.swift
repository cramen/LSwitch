#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryWindowOrdinaryTests: XCTestCase {
    @MainActor
    func testRetainedCoordinatorProgressReachesMetadataBeforeAnyPayloadDisclosure() throws {
        let source = try OrdinaryWindowTestSource(attemptPost: true)
        let session = RecoveryWindowSession()
        let metadata = try source.metadata()
        XCTAssertTrue(session.show(metadata, actions: source.actions))
        XCTAssertEqual(session.snapshot.metadata?.ordinaryDelivery, source.coordinator.metadata?.ordinaryDelivery)
        XCTAssertEqual(session.snapshot.metadata?.ordinaryDelivery?.attemptedPosts, 1)
        XCTAssertEqual(session.snapshot.metadata?.ordinaryDelivery?.returnedPosts, 0)
        XCTAssertEqual(session.snapshot.metadata?.ordinaryDelivery?.possiblyAlreadyDelivered, true)
        XCTAssertEqual(session.snapshot.metadata?.reason, .ordinaryDeliveryUnconfirmed)
        XCTAssertNil(session.snapshot.projection)
        XCTAssertNil(session.editFragment(ordinal: 0))
        XCTAssertNil(source.coordinator.revealedProjection)
        XCTAssertEqual(source.reveals, 0)
        XCTAssertTrue(session.reveal())
        XCTAssertEqual(source.reveals, 1)
        XCTAssertEqual(session.snapshot.projection?.entries.count, 3)
    }

    @MainActor
    func testHideReopenAndProtectionUpdatePreserveWarningWithoutRevealingDraft() throws {
        let source = try OrdinaryWindowTestSource(attemptPost: true)
        let session = RecoveryWindowSession()
        session.show(try source.metadata(), actions: source.actions)
        XCTAssertTrue(session.reveal())
        let draft = try XCTUnwrap(session.editFragment(ordinal: 0))
        XCTAssertTrue(session.saveDraft("user edited fragment", token: draft.token))
        session.hide()
        XCTAssertNil(session.snapshot.projection)
        XCTAssertEqual(session.snapshot.metadata?.ordinaryDelivery?.possiblyAlreadyDelivered, true)
        for protection: RecoveryWindowProtection in [.off, .unavailable, .unverified] {
            source.coordinator.show()
            XCTAssertTrue(session.show(try source.metadata(protection: protection), actions: source.actions))
            XCTAssertEqual(session.snapshot.metadata?.protection, protection)
            XCTAssertEqual(session.snapshot.metadata?.ordinaryDelivery?.possiblyAlreadyDelivered, true)
            XCTAssertEqual(session.snapshot.metadata?.counts, .init(events: 3, utf16Bytes: 6))
            XCTAssertNil(session.snapshot.projection)
            XCTAssertNil(session.editFragment(ordinal: 0))
        }
        XCTAssertEqual(source.reveals, 1)
        XCTAssertTrue(session.reveal())
        XCTAssertEqual(session.editFragment(ordinal: 0)?.text, "user edited fragment")
        XCTAssertFalse(session.saveDraft("stale", token: draft.token))
    }

    @MainActor
    func testNoAttemptAndLegacyMetadataDoNotClaimThatEditorIsUnchanged() throws {
        let source = try OrdinaryWindowTestSource(attemptPost: false)
        let session = RecoveryWindowSession()
        session.show(try source.metadata(), actions: source.actions)
        XCTAssertEqual(session.snapshot.metadata?.ordinaryDelivery?.attemptedPosts, 0)
        XCTAssertEqual(session.snapshot.metadata?.ordinaryDelivery?.possiblyAlreadyDelivered, false)
        XCTAssertEqual(session.snapshot.metadata?.reason, .ordinaryDeliveryUnconfirmed)
        XCTAssertEqual(session.snapshot.metadata?.protection, .unavailable)
        XCTAssertNil(session.snapshot.projection)
        XCTAssertEqual(source.reveals, 0)
        let legacy = RecoveryWindowTestSource()
        let separate = RecoveryWindowSession()
        separate.show(legacy.metadata, actions: legacy.actions)
        XCTAssertNil(separate.snapshot.metadata?.ordinaryDelivery)
        XCTAssertEqual(separate.snapshot.metadata?.reason, .cleanupUnconfirmed)
        XCTAssertNil(separate.snapshot.projection)
        XCTAssertEqual(legacy.reveals, 0)
    }

    @MainActor
    func testDeletionZerosStoredCountsWithoutErasingDeliveryHistoryOrRevealingPayload() throws {
        let source = try OrdinaryWindowTestSource(attemptPost: true)
        let session = RecoveryWindowSession()
        let before = try source.metadata()
        session.show(before, actions: source.actions)
        let intent = try XCTUnwrap(session.requestDeletion())
        XCTAssertEqual(session.resolveDeletion(intent, confirm: true), .deleted)
        XCTAssertEqual(source.coordinator.metadata?.eventCount, 0)
        XCTAssertEqual(session.snapshot.metadata?.counts, .init(events: 0, utf16Bytes: 0))
        XCTAssertEqual(session.snapshot.metadata?.ordinaryDelivery, before.ordinaryDelivery)
        session.hide()
        XCTAssertTrue(session.show(before, actions: source.actions), "Старые metadata не возвращают RAM-счётчики")
        XCTAssertEqual(session.snapshot.metadata?.counts, .init(events: 0, utf16Bytes: 0))
        XCTAssertEqual(session.snapshot.metadata?.ordinaryDelivery?.possiblyAlreadyDelivered, true)
        XCTAssertTrue(session.show(try source.metadata(protection: .off), actions: source.actions))
        XCTAssertEqual(session.snapshot.metadata?.protection, .off)
        XCTAssertEqual(session.snapshot.metadata?.ordinaryDelivery, before.ordinaryDelivery)
        XCTAssertFalse(session.reveal())
        XCTAssertNil(session.snapshot.projection)
        XCTAssertEqual(source.reveals, 0)
    }
}

@MainActor
private final class OrdinaryWindowTestSource {
    let fixture: OrdinaryCustodyFixture
    var reveals = 0
    var coordinator: RecoveryCoordinator { fixture.recovery.coordinator }

    init(attemptPost: Bool) throws {
        fixture = try OrdinaryCustodyFixture()
        if attemptPost {
            _ = fixture.custody.dispatch(policy: OrdinaryCustodyFixture.policy, actions: .init(post: { _ in
                throw OrdinaryCustodyFixture.PostFailure.injected
            }))
        } else {
            fixture.custody.requestRetention()
        }
        let proof = try XCTUnwrap(fixture.custody.terminalProof)
        guard case .adopted = coordinator.adoptRetainedOrdinary(proof: proof) else {
            throw OrdinaryCustodyFixture.PostFailure.injected
        }
    }

    func metadata(protection: RecoveryWindowProtection = .unavailable) throws -> RecoveryWindowMetadata {
        let stored = try XCTUnwrap(coordinator.metadata)
        return .init(recordIdentifier: stored.identifier, applicationName: "Тестовый редактор",
                     counts: .init(events: stored.eventCount, utf16Bytes: stored.utf16Bytes),
                     reason: .ordinaryDeliveryUnconfirmed, protection: protection,
                     ordinaryDelivery: stored.ordinaryDelivery)
    }

    var actions: RecoveryWindowActions {
        .init(reveal: { identifier in
            guard self.coordinator.metadata?.identifier == identifier else { return nil }
            self.reveals += 1
            guard let intent = self.coordinator.requestReveal(), self.coordinator.reveal(intent) else { return nil }
            return self.coordinator.revealedProjection
        }, requestDeletion: { identifier in
            guard self.coordinator.metadata?.identifier == identifier,
                  let intent = self.coordinator.requestDeletion() else { return nil }
            return .init(recordIdentifier: identifier,
                         confirm: { self.coordinator.confirmDeletion(intent) == .deleted },
                         cancel: { _ = self.coordinator.cancelDeletion(intent) })
        }, didHide: { _ in self.coordinator.hide() })
    }
}
#endif
