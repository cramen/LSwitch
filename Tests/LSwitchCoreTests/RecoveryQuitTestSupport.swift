import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class RecoveryQuitTestFixture {
    let source: RecoveryTestFixture
    let window = RecoveryWindowSession()
    let identifier: UUID

    init(text: String? = "saved", reader: RecoveryEventReader? = nil) throws {
        let source = try RecoveryTestFixture(eventReader: reader)
        self.source = source
        let hold = try source.begin()
        if let text { XCTAssertEqual(try hold.append(text), .accepted) }
        identifier = try source.adopt(hold)
        reopen()
    }

    var metadata: RecoveryWindowMetadata {
        let counts = source.coordinator.metadata
        return .init(recordIdentifier: identifier, applicationName: "Тестовый редактор",
                     counts: .init(events: counts?.eventCount ?? 0, utf16Bytes: counts?.utf16Bytes ?? 0),
                     reason: .cleanupUnconfirmed, protection: .unverified)
    }

    var actions: RecoveryWindowActions {
        let coordinator = source.coordinator
        return .init(reveal: { record in
            guard coordinator.metadata?.identifier == record, let intent = coordinator.requestReveal(),
                  coordinator.reveal(intent) else { return nil }
            return coordinator.revealedProjection
        }, requestDeletion: { record in
            guard coordinator.metadata?.identifier == record, let intent = coordinator.requestDeletion() else {
                return nil
            }
            return .init(recordIdentifier: record, confirm: {
                coordinator.confirmDeletion(intent) == .deleted
            }, cancel: { _ = coordinator.cancelDeletion(intent) })
        }, didHide: { _ in coordinator.hide() })
    }

    func reopen() {
        source.coordinator.show()
        window.show(metadata, actions: actions)
    }

    func request() throws -> RecoveryWindowQuitIntent {
        let request = window.requestQuit(actions: source.coordinator.quitActions)
        guard case .confirmationRequired(let intent) = request else {
            throw RecoveryQuitTestError.confirmationMissing
        }
        return intent
    }

    func editedDraft() throws -> RecoveryWindowDraft {
        XCTAssertTrue(window.reveal())
        let draft = try XCTUnwrap(window.editFragment(ordinal: 0))
        XCTAssertTrue(window.saveDraft("edited draft", token: draft.token))
        return draft
    }
}

enum RecoveryQuitTestError: Error { case confirmationMissing }
