import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryWindowDeletionTests: XCTestCase {
    @MainActor
    func testCancelRetainsDraftAndLateConfirmDoesNotDelete() throws {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        session.reveal()
        let draft = try XCTUnwrap(session.editFragment(ordinal: 0))
        session.saveDraft("saved draft", token: draft.token)
        let intent = try XCTUnwrap(session.requestDeletion())
        XCTAssertNil(session.requestDeletion(), "Одна активная sheet")
        XCTAssertEqual(session.resolveDeletion(intent, confirm: false), .cancelled)
        XCTAssertEqual(session.resolveDeletion(intent, confirm: true), .stale)
        XCTAssertEqual(source.confirmations, 0)
        XCTAssertEqual(source.cancellations, 1)
        XCTAssertEqual(session.editFragment(ordinal: 0)?.text, "saved draft")
    }

    @MainActor
    func testHiddenSheetAndForeignIntentCannotDeleteCurrentRecord() throws {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        let hidden = try XCTUnwrap(session.requestDeletion())
        session.hide()
        session.show(source.metadata, actions: source.actions)
        XCTAssertEqual(session.resolveDeletion(hidden, confirm: true), .stale)
        let other = RecoveryWindowSession()
        other.show(source.metadata, actions: source.actions)
        let foreign = try XCTUnwrap(other.requestDeletion())
        XCTAssertEqual(session.resolveDeletion(foreign, confirm: true), .stale)
        XCTAssertEqual(source.confirmations, 0)
        XCTAssertEqual(source.cancellations, 1)
        XCTAssertFalse(session.snapshot.isDeleted)
    }

    @MainActor
    func testDeleteClearsDisclosureCopiesAndLateCallbackCannotDeleteNewRecord() throws {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        session.reveal()
        let draft = try XCTUnwrap(session.editFragment(ordinal: 0))
        session.saveDraft("edited", token: draft.token)
        let intent = try XCTUnwrap(session.requestDeletion())
        XCTAssertEqual(session.resolveDeletion(intent, confirm: true), .deleted)
        XCTAssertTrue(session.snapshot.isDeleted)
        XCTAssertEqual(session.snapshot.metadata?.counts, .init(events: 0, utf16Bytes: 0))
        XCTAssertNil(session.snapshot.projection)
        XCTAssertFalse(session.reveal())
        XCTAssertFalse(session.saveDraft("late", token: draft.token))
        XCTAssertNil(session.editFragment(ordinal: 0))
        XCTAssertTrue(session.show(source.metadata, actions: source.actions))
        XCTAssertEqual(session.snapshot.metadata?.counts, .init(events: 0, utf16Bytes: 0))
        XCTAssertFalse(session.reveal())
        let other = RecoveryWindowTestSource()
        XCTAssertTrue(session.show(other.metadata, actions: other.actions))
        XCTAssertEqual(session.resolveDeletion(intent, confirm: true), .stale)
        XCTAssertEqual(source.confirmations, 1)
        XCTAssertEqual(other.confirmations, 0)
        XCTAssertTrue(session.reveal())
        XCTAssertEqual(session.editFragment(ordinal: 0)?.text, "first")
    }

    @MainActor
    func testRefusedDeletionKeepsDraftAndRequiresNewExplicitRequest() throws {
        let source = RecoveryWindowTestSource()
        source.deletionAllowed = false
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        session.reveal()
        let draft = try XCTUnwrap(session.editFragment(ordinal: 0))
        session.saveDraft("retained", token: draft.token)
        let intent = try XCTUnwrap(session.requestDeletion())
        XCTAssertEqual(session.resolveDeletion(intent, confirm: true), .refused)
        XCTAssertFalse(session.snapshot.isDeleted)
        XCTAssertEqual(session.snapshot.notice, .deletionRefused)
        XCTAssertEqual(session.editFragment(ordinal: 0)?.text, "retained")
        XCTAssertEqual(session.resolveDeletion(intent, confirm: true), .stale)
        XCTAssertEqual(source.confirmations, 1)
        XCTAssertNotNil(session.requestDeletion())
    }

    @MainActor
    func testForeignDeletionHandleAndReentrantHideCancelWithoutConfirmation() {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        source.deletionRecord = UUID()
        XCTAssertNil(session.requestDeletion())
        source.deletionRecord = nil
        source.onRequestDeletion = { session.hide() }
        XCTAssertNil(session.requestDeletion())
        XCTAssertEqual(source.confirmations, 0)
        XCTAssertEqual(source.cancellations, 2)
        XCTAssertFalse(session.snapshot.isDeleted)
    }

    @MainActor
    func testConfirmedDeleteClearsPayloadEvenIfCallbackHidesAndReopensWindow() throws {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        session.reveal()
        let intent = try XCTUnwrap(session.requestDeletion())
        source.onConfirm = {
            session.hide()
            session.show(source.metadata, actions: source.actions)
            session.reveal()
        }
        XCTAssertEqual(session.resolveDeletion(intent, confirm: true), .deleted)
        XCTAssertTrue(session.snapshot.isDeleted)
        XCTAssertNil(session.snapshot.projection)
        XCTAssertNil(session.editFragment(ordinal: 0))
        XCTAssertEqual(source.confirmations, 1)
    }

    @MainActor
    func testReentrantDeletionRequestCannotIssueSecondIntentOrRevealPayload() throws {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        source.onRequestDeletion = {
            XCTAssertNil(session.requestDeletion())
            XCTAssertFalse(session.reveal())
        }
        let intent = try XCTUnwrap(session.requestDeletion())
        XCTAssertEqual(source.deletionRequests, 1)
        XCTAssertEqual(source.reveals, 0)
        XCTAssertEqual(session.resolveDeletion(intent, confirm: false), .cancelled)
        XCTAssertEqual(source.cancellations, 1)
    }

    @MainActor
    func testConfirmationBlocksNestedDeletionRevealAndEditingUntilDecisionReturns() throws {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        session.reveal()
        let draft = try XCTUnwrap(session.editFragment(ordinal: 0))
        let intent = try XCTUnwrap(session.requestDeletion())
        source.onConfirm = {
            XCTAssertNil(session.requestDeletion())
            XCTAssertFalse(session.reveal())
            XCTAssertNil(session.editFragment(ordinal: 0))
            XCTAssertFalse(session.saveDraft("late", token: draft.token))
        }
        XCTAssertEqual(session.resolveDeletion(intent, confirm: true), .deleted)
        XCTAssertNil(session.requestDeletion())
        XCTAssertEqual(session.resolveDeletion(intent, confirm: true), .stale)
        XCTAssertEqual(source.deletionRequests, 1)
        XCTAssertEqual(source.confirmations, 1)
        XCTAssertEqual(source.reveals, 1)
    }

    @MainActor
    func testRefusedConfirmationInvalidatesRemovedEditorButKeepsPrivateDraft() throws {
        let source = RecoveryWindowTestSource()
        source.deletionAllowed = false
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        session.reveal()
        let draft = try XCTUnwrap(session.editFragment(ordinal: 0))
        session.saveDraft("retained", token: draft.token)
        let intent = try XCTUnwrap(session.requestDeletion())
        XCTAssertEqual(session.resolveDeletion(intent, confirm: true), .refused)
        XCTAssertFalse(session.saveDraft("", token: draft.token))
        XCTAssertEqual(session.editFragment(ordinal: 0)?.text, "retained")
        XCTAssertNotNil(session.snapshot.projection)
    }
}
