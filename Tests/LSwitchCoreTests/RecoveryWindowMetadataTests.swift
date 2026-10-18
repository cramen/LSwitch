import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryWindowMetadataTests: XCTestCase {
    @MainActor
    func testMetadataRefreshKeepsDisclosureActiveDraftAndEditorTokenWithoutReaderCalls() throws {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        XCTAssertTrue(session.reveal())
        let draft = try XCTUnwrap(session.editFragment(ordinal: 0))
        XCTAssertTrue(session.saveDraft("user copy", token: draft.token))
        let updated = metadata(source, protection: .off)
        XCTAssertTrue(session.updateMetadata(updated))
        XCTAssertEqual(session.snapshot.metadata, updated)
        XCTAssertTrue(session.snapshot.isVisible)
        XCTAssertEqual(session.snapshot.projection?.recordIdentifier, source.identifier)
        XCTAssertEqual(session.snapshot.projection?.entries.map(\.ordinal), [0, 1, 2])
        XCTAssertEqual(source.reveals, 1)
        XCTAssertTrue(source.hidden.isEmpty)
        XCTAssertTrue(session.saveDraft("continued edit", token: draft.token), "Token не инвалидируется metadata")
        XCTAssertEqual(session.editFragment(ordinal: 0)?.text, "continued edit")
    }

    @MainActor
    func testHiddenMetadataRefreshDoesNotReopenOrRevealAndKeepsPrivateDraft() throws {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        session.reveal()
        let draft = try XCTUnwrap(session.editFragment(ordinal: 0))
        session.saveDraft("retained draft", token: draft.token)
        session.hide()
        let updated = metadata(source, protection: .unavailable)
        XCTAssertTrue(session.updateMetadata(updated))
        XCTAssertFalse(session.snapshot.isVisible)
        XCTAssertNil(session.snapshot.projection)
        XCTAssertFalse(session.reveal())
        XCTAssertNil(session.editFragment(ordinal: 0))
        XCTAssertEqual(source.reveals, 1)
        XCTAssertEqual(source.hidden, [source.identifier])
        session.show(updated, actions: source.actions)
        XCTAssertNil(session.snapshot.projection)
        XCTAssertTrue(session.reveal())
        XCTAssertEqual(session.editFragment(ordinal: 0)?.text, "retained draft")
    }

    @MainActor
    func testForeignRecordRefreshCannotChangeMetadataPayloadOrCurrentEditorToken() throws {
        let source = RecoveryWindowTestSource()
        let foreign = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        session.reveal()
        let draft = try XCTUnwrap(session.editFragment(ordinal: 0))
        XCTAssertFalse(session.updateMetadata(metadata(foreign, protection: .off)))
        XCTAssertEqual(session.snapshot.metadata, source.metadata)
        XCTAssertEqual(session.snapshot.projection?.recordIdentifier, source.identifier)
        XCTAssertTrue(session.saveDraft("still current", token: draft.token))
        XCTAssertEqual(source.reveals, 1)
        XCTAssertEqual(foreign.reveals, 0)
    }

    @MainActor
    func testPendingConfirmationRemainsBoundAndIsNotCancelledByMetadataRefresh() throws {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        let intent = try XCTUnwrap(session.requestDeletion())
        let updated = metadata(source, protection: .unavailable)
        XCTAssertTrue(session.updateMetadata(updated))
        XCTAssertNil(session.requestDeletion(), "Прежнее подтверждение остаётся активным")
        XCTAssertFalse(session.reveal())
        XCTAssertEqual(source.deletionRequests, 1)
        XCTAssertEqual(source.cancellations, 0)
        XCTAssertEqual(session.resolveDeletion(intent, confirm: true), .deleted)
        XCTAssertEqual(source.confirmations, 1)
        XCTAssertEqual(session.snapshot.metadata?.counts, .init(events: 0, utf16Bytes: 0))
        XCTAssertEqual(session.snapshot.metadata?.ordinaryDelivery, updated.ordinaryDelivery)
        XCTAssertEqual(session.resolveDeletion(intent, confirm: true), .stale)
        XCTAssertEqual(source.reveals, 0)
    }

    @MainActor
    func testNoRecordIsNotCreatedAndDeletedRecordCannotBeResurrectedByRefresh() throws {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        XCTAssertFalse(session.updateMetadata(source.metadata))
        XCTAssertNil(session.snapshot.metadata)
        session.show(source.metadata, actions: source.actions)
        let intent = try XCTUnwrap(session.requestDeletion())
        XCTAssertEqual(session.resolveDeletion(intent, confirm: true), .deleted)
        let updated = metadata(source, protection: .off)
        XCTAssertTrue(session.updateMetadata(updated))
        XCTAssertTrue(session.snapshot.isDeleted)
        XCTAssertEqual(session.snapshot.notice, .deleted)
        XCTAssertEqual(session.snapshot.metadata?.counts, .init(events: 0, utf16Bytes: 0))
        XCTAssertEqual(session.snapshot.metadata?.protection, .off)
        XCTAssertEqual(session.snapshot.metadata?.ordinaryDelivery, updated.ordinaryDelivery)
        XCTAssertNil(session.snapshot.projection)
        XCTAssertFalse(session.reveal())
        XCTAssertEqual(source.reveals, 0)
    }

    @MainActor
    private func metadata(
        _ source: RecoveryWindowTestSource, protection: RecoveryWindowProtection
    ) -> RecoveryWindowMetadata {
        .init(recordIdentifier: source.identifier, applicationName: "Обновлённое имя",
              counts: .init(events: 3, utf16Bytes: 22), reason: .ordinaryDeliveryUnconfirmed,
              protection: protection, ordinaryDelivery: .init(
                totalEvents: 3, attemptedPosts: 1, returnedPosts: 0, failure: .routeUnavailable
              ))
    }
}
