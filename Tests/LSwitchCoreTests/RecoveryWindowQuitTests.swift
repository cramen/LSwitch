import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryWindowQuitTests: XCTestCase {
    @MainActor
    func testNoRecordAllowsQuitButUnfinishedHandoverAndMissingOwnerRefuseIt() throws {
        let source = try RecoveryTestFixture()
        let window = RecoveryWindowSession()
        XCTAssertEqual(window.requestQuit(actions: source.coordinator.quitActions), .allowed)
        _ = try source.begin()
        XCTAssertEqual(window.requestQuit(actions: source.coordinator.quitActions), .handoverRequired)
        var owner: RecoveryCoordinator? = RecoveryCoordinator()
        let orphaned = try XCTUnwrap(owner).quitActions
        owner = nil
        XCTAssertEqual(window.requestQuit(actions: orphaned), .handoverRequired)
    }

    @MainActor
    func testCancelPreservesRealOriginalAndDraftWithoutNewPayloadRead() throws {
        var reads = 0
        let fixture = try RecoveryQuitTestFixture(reader: RecoveryEventReader(onRead: { reads += 1 }))
        _ = try fixture.editedDraft()
        let before = reads
        let intent = try fixture.request()
        XCTAssertNil(fixture.window.snapshot.projection)
        XCTAssertEqual(reads, before)
        XCTAssertEqual(fixture.window.resolveQuit(intent, confirm: false), .cancelled)
        XCTAssertEqual(fixture.window.resolveQuit(intent, confirm: true), .stale)
        XCTAssertEqual(fixture.source.coordinator.metadata?.eventCount, 1)
        XCTAssertFalse(try XCTUnwrap(fixture.source.coordinator.metadata).payloadDeleted)
        XCTAssertTrue(fixture.window.reveal())
        XCTAssertEqual(fixture.window.editFragment(ordinal: 0)?.text, "edited draft")
    }

    @MainActor
    func testConfirmedQuitClearsOriginalDraftAndOldEditorOnceButKeepsDangerousTarget() throws {
        let fixture = try RecoveryQuitTestFixture()
        let draft = try fixture.editedDraft()
        let intent = try fixture.request()
        XCTAssertEqual(fixture.window.resolveQuit(intent, confirm: true), .quitAllowed)
        XCTAssertEqual(fixture.window.resolveQuit(intent, confirm: true), .stale)
        XCTAssertTrue(try XCTUnwrap(fixture.source.coordinator.metadata).payloadDeleted)
        XCTAssertEqual(fixture.source.coordinator.metadata?.eventCount, 0)
        XCTAssertTrue(fixture.source.coordinator.hasPendingRecovery)
        XCTAssertTrue(fixture.window.snapshot.isDeleted)
        XCTAssertEqual(fixture.window.snapshot.metadata?.counts, .init(events: 0, utf16Bytes: 0))
        XCTAssertFalse(fixture.window.saveDraft("late", token: draft.token))
        XCTAssertNil(fixture.window.editFragment(ordinal: 0))
        // Удалённый payload не отменяет необходимость решения о неподтверждённой цели.
        XCTAssertEqual(fixture.window.resolveQuit(try fixture.request(), confirm: false), .cancelled)
    }

    @MainActor
    func testHiddenQuitCancelPreservesDraftAndConfirmationDoesNotRequireReveal() throws {
        let fixture = try RecoveryQuitTestFixture()
        _ = try fixture.editedDraft()
        fixture.window.hide()
        let first = try fixture.request()
        XCTAssertFalse(fixture.window.snapshot.isVisible)
        XCTAssertNil(fixture.window.snapshot.projection)
        XCTAssertEqual(fixture.window.resolveQuit(first, confirm: false), .cancelled)
        fixture.reopen()
        XCTAssertTrue(fixture.window.reveal())
        XCTAssertEqual(fixture.window.editFragment(ordinal: 0)?.text, "edited draft")
        fixture.window.hide()
        XCTAssertEqual(fixture.window.resolveQuit(try fixture.request(), confirm: true), .quitAllowed)
        XCTAssertTrue(try XCTUnwrap(fixture.source.coordinator.metadata).payloadDeleted)
    }

    @MainActor
    func testHideCancelsPendingQuitAndLateConfirmationCannotDeleteAfterReopen() throws {
        let fixture = try RecoveryQuitTestFixture()
        let intent = try fixture.request()
        fixture.window.hide()
        fixture.reopen()
        XCTAssertEqual(fixture.window.resolveQuit(intent, confirm: true), .stale)
        XCTAssertEqual(fixture.source.coordinator.metadata?.eventCount, 1)
        XCTAssertNotEqual(try fixture.request(), intent)
    }

    @MainActor
    func testRepeatedQuitUsesOneRequestAndSupersedesDeletionWithoutExecutingIt() throws {
        let fixture = try RecoveryQuitTestFixture()
        let deletion = try XCTUnwrap(fixture.window.requestDeletion())
        var requests = 0
        let actions = RecoveryQuitActions {
            requests += 1
            return fixture.source.coordinator.quitActions.request()
        }
        let first = fixture.window.requestQuit(actions: actions)
        XCTAssertEqual(fixture.window.requestQuit(actions: actions), first)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(fixture.window.resolveDeletion(deletion, confirm: true), .stale)
        XCTAssertNil(fixture.window.requestDeletion())
        XCTAssertFalse(fixture.window.reveal())
        XCTAssertEqual(fixture.source.coordinator.metadata?.eventCount, 1)
    }

    @MainActor
    func testForeignConfirmationOrAllowedReplyCannotDiscardBoundWindowRecord() throws {
        let fixture = try RecoveryQuitTestFixture()
        var cancellations = 0
        let foreign = RecoveryQuitActions {
            .confirmationRequired(.init(recordIdentifier: UUID(), confirm: {
                XCTFail("Чужое подтверждение не вызывается")
                return true
            }, cancel: { cancellations += 1 }))
        }
        XCTAssertEqual(fixture.window.requestQuit(actions: foreign), .handoverRequired)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(fixture.window.requestQuit(actions: .init(request: { .allowed })), .handoverRequired)
        XCTAssertEqual(fixture.source.coordinator.metadata?.eventCount, 1)
    }

    @MainActor
    func testReentrantHideDuringRequestCancelsReturnedConfirmation() throws {
        let fixture = try RecoveryQuitTestFixture()
        var confirmations = 0
        var cancellations = 0
        let actions = RecoveryQuitActions {
            fixture.window.hide()
            return .confirmationRequired(.init(recordIdentifier: fixture.identifier, confirm: {
                confirmations += 1
                return true
            }, cancel: { cancellations += 1 }))
        }
        XCTAssertEqual(fixture.window.requestQuit(actions: actions), .handoverRequired)
        XCTAssertEqual(confirmations, 0)
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(fixture.source.coordinator.metadata?.eventCount, 1)
    }

    @MainActor
    func testRefusedConfirmationKeepsOriginalAndPrivateDraft() throws {
        let fixture = try RecoveryQuitTestFixture()
        let draft = try fixture.editedDraft()
        let actions = RecoveryQuitActions {
            .confirmationRequired(.init(recordIdentifier: fixture.identifier, confirm: { false }, cancel: {}))
        }
        guard case .confirmationRequired(let intent) = fixture.window.requestQuit(actions: actions) else {
            return XCTFail("Нужно подтверждение")
        }
        XCTAssertEqual(fixture.window.resolveQuit(intent, confirm: true), .refused)
        XCTAssertEqual(fixture.window.snapshot.notice, .deletionRefused)
        XCTAssertFalse(fixture.window.saveDraft("late", token: draft.token))
        XCTAssertEqual(fixture.source.coordinator.metadata?.eventCount, 1)
        XCTAssertTrue(fixture.window.reveal())
        XCTAssertEqual(fixture.window.editFragment(ordinal: 0)?.text, "edited draft")
    }

    @MainActor
    func testReentrantConfirmationCannotRevealOrChangeDraftBeforeDeletionCompletes() throws {
        let fixture = try RecoveryQuitTestFixture()
        _ = try fixture.editedDraft()
        let actions = RecoveryQuitActions {
            guard case .confirmationRequired(let request) = fixture.source.coordinator.quitActions.request() else {
                return .handoverRequired
            }
            return .confirmationRequired(.init(recordIdentifier: fixture.identifier, confirm: {
                XCTAssertFalse(fixture.window.reveal())
                XCTAssertNil(fixture.window.requestDeletion())
                XCTAssertEqual(fixture.window.requestQuit(actions: fixture.source.coordinator.quitActions),
                               .handoverRequired)
                fixture.window.hide()
                fixture.reopen()
                return request.confirm()
            }, cancel: { request.cancel() }))
        }
        guard case .confirmationRequired(let intent) = fixture.window.requestQuit(actions: actions) else {
            return XCTFail("Нужно подтверждение")
        }
        XCTAssertEqual(fixture.window.resolveQuit(intent, confirm: true), .quitAllowed)
        XCTAssertTrue(fixture.window.snapshot.isDeleted)
        XCTAssertNil(fixture.window.snapshot.projection)
        XCTAssertNil(fixture.window.editFragment(ordinal: 0))
    }

    @MainActor
    func testEmptyDangerousRecordStillRequiresExplicitQuitConfirmation() throws {
        let fixture = try RecoveryQuitTestFixture(text: nil)
        XCTAssertEqual(fixture.window.snapshot.metadata?.counts.events, 0)
        let intent = try fixture.request()
        XCTAssertEqual(fixture.window.resolveQuit(intent, confirm: false), .cancelled)
        XCTAssertTrue(fixture.source.coordinator.hasPendingRecovery)
    }

    @MainActor
    func testDeletionCancellationCannotStartNestedQuitBeforeOuterRequestLatch() throws {
        let fixture = try RecoveryQuitTestFixture()
        var nestedRequests = 0
        var nestedResult: RecoveryWindowQuitRequest?
        let nested = RecoveryQuitActions { nestedRequests += 1; return .allowed }
        replaceDeletionCancellation(fixture) { [weak window = fixture.window] in
            nestedResult = window?.requestQuit(actions: nested)
        }
        XCTAssertNotNil(fixture.window.requestDeletion())
        let outer = try fixture.request()
        XCTAssertEqual(nestedResult, .handoverRequired)
        XCTAssertEqual(nestedRequests, 0)
        XCTAssertEqual(fixture.source.coordinator.metadata?.eventCount, 1)
        XCTAssertEqual(fixture.window.resolveQuit(outer, confirm: false), .cancelled)
    }

    @MainActor
    func testDeletionCancellationCannotRevealOrEditDuringQuitPreparation() throws {
        var reads = 0
        let fixture = try RecoveryQuitTestFixture(reader: RecoveryEventReader(onRead: { reads += 1 }))
        var token: RecoveryWindowEditorToken?
        var cancellations = 0
        replaceDeletionCancellation(fixture) { [weak window = fixture.window] in
            cancellations += 1
            guard let window, let token else { return XCTFail("Нужен действующий редактор") }
            XCTAssertFalse(window.reveal())
            XCTAssertNil(window.editFragment(ordinal: 0))
            XCTAssertFalse(window.saveDraft("unexpected edit", token: token))
        }
        token = try fixture.editedDraft().token
        let before = reads
        XCTAssertNotNil(fixture.window.requestDeletion())
        let outer = try fixture.request()
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(reads, before)
        XCTAssertEqual(fixture.window.resolveQuit(outer, confirm: false), .cancelled)
        XCTAssertTrue(fixture.window.reveal())
        XCTAssertEqual(fixture.window.editFragment(ordinal: 0)?.text, "edited draft")
    }

    @MainActor
    private func replaceDeletionCancellation(_ fixture: RecoveryQuitTestFixture, callback: @escaping () -> Void) {
        let actions = fixture.actions
        fixture.window.show(fixture.metadata, actions: .init(reveal: actions.reveal, requestDeletion: { record in
            guard let request = actions.requestDeletion(record) else { return nil }
            return .init(recordIdentifier: record, confirm: { request.confirm() }, cancel: {
                request.cancel()
                callback()
            })
        }, didHide: actions.didHide))
    }
}
