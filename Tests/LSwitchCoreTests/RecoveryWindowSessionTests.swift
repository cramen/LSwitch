import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryWindowSessionTests: XCTestCase {
    @MainActor
    func testMetadataAndRepeatedShowNeverReadPayloadOrPermitEditing() {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        XCTAssertTrue(session.show(source.metadata, actions: source.actions))
        XCTAssertTrue(session.show(source.metadata, actions: source.actions))
        XCTAssertEqual(source.reveals, 0)
        XCTAssertNil(session.snapshot.projection)
        XCTAssertNil(session.editFragment(ordinal: 0))
        session.hide()
        XCTAssertFalse(session.reveal())
        XCTAssertEqual(source.reveals, 0)
        XCTAssertEqual(source.hidden, [source.identifier])
    }

    @MainActor
    func testHideAndReopenRequireNewRevealAndPreserveExactEditedCopy() throws {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        XCTAssertTrue(session.reveal())
        let first = try XCTUnwrap(session.editFragment(ordinal: 0))
        let edited = "е\u{0301} 😀 мой черновик"
        XCTAssertTrue(session.saveDraft(edited, token: first.token))
        session.hide()
        XCTAssertNil(session.snapshot.projection)
        XCTAssertFalse(session.saveDraft("late", token: first.token))
        XCTAssertTrue(session.show(source.metadata, actions: source.actions))
        XCTAssertNil(session.snapshot.projection)
        XCTAssertNil(session.editFragment(ordinal: 0))
        XCTAssertTrue(session.reveal())
        let restored = try XCTUnwrap(session.editFragment(ordinal: 0))
        XCTAssertTrue(restored.text.utf16.elementsEqual(edited.utf16))
        XCTAssertFalse(session.saveDraft("late again", token: first.token))
        XCTAssertEqual(source.reveals, 2)
        XCTAssertEqual(source.projection.entries.count, 3, "Редактирование копии не изменяет оригиналы")
    }

    @MainActor
    func testPerFragmentCopiesKeepCommandsSeparateAndInvalidatePreviousEditor() throws {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        session.reveal()
        XCTAssertNil(session.editFragment(ordinal: 1), "Команда не превращается в текст")
        let first = try XCTUnwrap(session.editFragment(ordinal: 0))
        XCTAssertEqual(first.text, "first")
        XCTAssertTrue(session.saveDraft("edited first", token: first.token))
        let second = try XCTUnwrap(session.editFragment(ordinal: 2))
        XCTAssertEqual(second.text, "second")
        XCTAssertFalse(session.saveDraft("stale", token: first.token))
        XCTAssertTrue(session.saveDraft("edited second", token: second.token))
        XCTAssertEqual(session.editFragment(ordinal: 0)?.text, "edited first")
        XCTAssertEqual(session.snapshot.projection?.entries.map(\.ordinal), [0, 1, 2])
    }

    @MainActor
    func testForeignAndFailedProjectionNeverExposePayload() {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        source.projection = .init(recordIdentifier: UUID(), entries: source.projection.entries, failure: nil)
        XCTAssertFalse(session.reveal())
        XCTAssertNil(session.snapshot.projection)
        XCTAssertEqual(session.snapshot.notice, .revealUnavailable)
        source.projection = .init(recordIdentifier: source.identifier, entries: [], failure: .payloadLimitExceeded)
        XCTAssertTrue(session.reveal())
        XCTAssertEqual(session.snapshot.projection?.failure, .payloadLimitExceeded)
        XCTAssertNil(session.editFragment(ordinal: 0))
    }

    @MainActor
    func testHideShowDuringRevealCannotPublishOldResult() {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        source.onReveal = {
            session.hide()
            session.show(source.metadata, actions: source.actions)
        }
        XCTAssertFalse(session.reveal())
        XCTAssertTrue(session.snapshot.isVisible)
        XCTAssertNil(session.snapshot.projection)
        source.onReveal = {}
        XCTAssertTrue(session.reveal())
        XCTAssertEqual(source.reveals, 2)
    }

    @MainActor
    func testNestedNewRevealIsNotOverwrittenByOldCallback() {
        let source = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        source.onReveal = {
            source.onReveal = {}
            XCTAssertTrue(session.reveal())
        }
        XCTAssertFalse(session.reveal())
        XCTAssertEqual(source.reveals, 2)
        XCTAssertEqual(session.snapshot.projection?.recordIdentifier, source.identifier)
    }

    @MainActor
    func testAnotherRecordCannotEvictPendingDraftsAndProtectionIsNotInferredFromVisibility() throws {
        let source = RecoveryWindowTestSource()
        let other = RecoveryWindowTestSource()
        let session = RecoveryWindowSession()
        session.show(source.metadata, actions: source.actions)
        session.reveal()
        let draft = try XCTUnwrap(session.editFragment(ordinal: 0))
        session.saveDraft("retained", token: draft.token)
        XCTAssertFalse(session.show(other.metadata, actions: other.actions))
        XCTAssertEqual(session.snapshot.metadata?.recordIdentifier, source.identifier)
        XCTAssertEqual(session.editFragment(ordinal: 0)?.text, "retained")
        for protection in [RecoveryWindowProtection.off, .unavailable, .unverified, .verifiedBlocking] {
            session.show(source.metadata(protection: protection), actions: source.actions)
            XCTAssertEqual(session.snapshot.metadata?.protection, protection)
            XCTAssertNil(session.snapshot.projection)
        }
        XCTAssertEqual(source.reveals, 1)
        XCTAssertEqual(other.reveals, 0)
    }
}

@MainActor
final class RecoveryWindowTestSource {
    let identifier: UUID
    var projection: RecoveryProjection
    var reveals = 0
    var deletionRequests = 0
    var confirmations = 0
    var cancellations = 0
    var hidden: [UUID] = []
    var deletionAllowed = true
    var deletionRecord: UUID?
    var onReveal: () -> Void = {}
    var onRequestDeletion: () -> Void = {}
    var onConfirm: () -> Void = {}

    init() {
        let identifier = UUID()
        self.identifier = identifier
        projection = .init(recordIdentifier: identifier, entries: [
            .init(ordinal: 0, content: .unicodeFragment(.init(text: "first"))),
            .init(ordinal: 1, content: .nonText(.editingKey(.backspace))),
            .init(ordinal: 2, content: .unicodeFragment(.init(text: "second")))
        ], failure: nil)
    }

    var metadata: RecoveryWindowMetadata { metadata(protection: .unverified) }

    func metadata(protection: RecoveryWindowProtection) -> RecoveryWindowMetadata {
        .init(recordIdentifier: identifier, applicationName: "Тестовый редактор",
              counts: .init(events: 3, utf16Bytes: 22), reason: .cleanupUnconfirmed, protection: protection)
    }

    var actions: RecoveryWindowActions {
        .init(reveal: { identifier in
            XCTAssertEqual(identifier, self.identifier)
            self.reveals += 1
            self.onReveal()
            return self.projection
        }, requestDeletion: { identifier in
            XCTAssertEqual(identifier, self.identifier)
            self.deletionRequests += 1
            self.onRequestDeletion()
            return .init(recordIdentifier: self.deletionRecord ?? identifier, confirm: {
                self.confirmations += 1
                self.onConfirm()
                return self.deletionAllowed
            }, cancel: { self.cancellations += 1 })
        }, didHide: { self.hidden.append($0) })
    }
}
