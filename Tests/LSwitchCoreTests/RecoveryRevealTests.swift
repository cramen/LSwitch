import Foundation
@testable import LSwitchCore
import XCTest

final class RecoveryRevealTests: XCTestCase {
    @MainActor
    func testAdoptionMetadataAndRequestDoNotReadPayloadUntilAcceptedReveal() throws {
        var reads = 0
        let fixture = try RecoveryTestFixture(eventReader: RecoveryEventReader(onRead: { reads += 1 }))
        XCTAssertNil(fixture.coordinator.requestReveal())
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append("a"), .accepted)
        XCTAssertEqual(try hold.append("б"), .accepted)
        let identifier = try fixture.adopt(hold)
        let before = try XCTUnwrap(fixture.coordinator.metadata)
        XCTAssertNil(fixture.coordinator.revealedProjection)
        let intent = try XCTUnwrap(fixture.coordinator.requestReveal())
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(fixture.coordinator.metadata, before)
        XCTAssertTrue(fixture.coordinator.reveal(intent))
        XCTAssertEqual(reads, 1)
        try assertProjection(fixture.coordinator, record: identifier, fragments: ["a", "б"])
        XCTAssertEqual(fixture.coordinator.metadata, before)
        hold.buffer.end { _ in XCTFail("Раскрытие не возвращает оригиналы прежнему владельцу") }
    }

    @MainActor
    func testRepeatedIntentDoesNotReadAgainButNewExplicitRequestCanRevealOriginals() throws {
        var reads = 0
        let fixture = try RecoveryTestFixture(eventReader: RecoveryEventReader(onRead: { reads += 1 }))
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append("saved"), .accepted)
        let identifier = try fixture.adopt(hold)
        let first = try XCTUnwrap(fixture.coordinator.requestReveal())
        XCTAssertTrue(fixture.coordinator.reveal(first))
        XCTAssertFalse(fixture.coordinator.reveal(first))
        XCTAssertEqual(reads, 1)
        let second = try XCTUnwrap(fixture.coordinator.requestReveal())
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(fixture.coordinator.reveal(second))
        XCTAssertEqual(reads, 2)
        try assertProjection(fixture.coordinator, record: identifier, fragments: ["saved"])
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
        XCTAssertEqual(fixture.coordinator.metadata?.payloadDeleted, false)
    }

    @MainActor
    func testForeignAndSupersededIntentsNeverCallReader() throws {
        var reads = 0
        let fixture = try RecoveryTestFixture(eventReader: RecoveryEventReader(onRead: { reads += 1 }))
        try fixture.adopt(fixture.begin())
        let foreign = try RecoveryTestFixture()
        try foreign.adopt(foreign.begin())
        let foreignIntent = try XCTUnwrap(foreign.coordinator.requestReveal())
        let stale = try XCTUnwrap(fixture.coordinator.requestReveal())
        let current = try XCTUnwrap(fixture.coordinator.requestReveal())
        XCTAssertFalse(fixture.coordinator.reveal(foreignIntent))
        XCTAssertFalse(fixture.coordinator.reveal(stale))
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(fixture.coordinator.reveal(current))
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(try XCTUnwrap(fixture.coordinator.revealedProjection).entries.isEmpty)
    }

    @MainActor
    func testHideInvalidatesUnusedIntentAndShowDoesNotRevealAutomatically() throws {
        var reads = 0
        let fixture = try RecoveryTestFixture(eventReader: RecoveryEventReader(onRead: { reads += 1 }))
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append(), .accepted)
        try fixture.adopt(hold)
        let intent = try XCTUnwrap(fixture.coordinator.requestReveal())
        fixture.coordinator.hide()
        XCTAssertFalse(fixture.coordinator.reveal(intent))
        XCTAssertNil(fixture.coordinator.requestReveal())
        fixture.coordinator.show()
        XCTAssertFalse(fixture.coordinator.reveal(intent))
        XCTAssertNil(fixture.coordinator.revealedProjection)
        XCTAssertEqual(reads, 0)
        let fresh = try XCTUnwrap(fixture.coordinator.requestReveal())
        XCTAssertTrue(fixture.coordinator.reveal(fresh))
        XCTAssertEqual(reads, 1)
        fixture.coordinator.hide()
        XCTAssertNil(fixture.coordinator.revealedProjection)
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
    }

    @MainActor
    func testDeleteAndConfirmedQuitInvalidateUnusedRevealWithoutReading() throws {
        for quitting in [false, true] {
            var reads = 0
            let fixture = try RecoveryTestFixture(eventReader: RecoveryEventReader(onRead: { reads += 1 }))
            let hold = try fixture.begin()
            XCTAssertEqual(try hold.append(), .accepted)
            try fixture.adopt(hold)
            let reveal = try XCTUnwrap(fixture.coordinator.requestReveal())
            if quitting {
                guard case .confirmationRequired(let intent) = fixture.coordinator.requestQuit() else {
                    XCTFail("Отсутствует quit intent"); return
                }
                XCTAssertEqual(fixture.coordinator.decideQuit(intent, choice: .deleteAndQuit), .quitAllowed)
            } else {
                let intent = try XCTUnwrap(fixture.coordinator.requestDeletion())
                XCTAssertEqual(fixture.coordinator.confirmDeletion(intent), .deleted)
            }
            XCTAssertFalse(fixture.coordinator.reveal(reveal))
            XCTAssertNil(fixture.coordinator.requestReveal())
            XCTAssertNil(fixture.coordinator.revealedProjection)
            XCTAssertEqual(reads, 0)
            XCTAssertEqual(fixture.coordinator.metadata?.payloadDeleted, true)
        }
    }

    @MainActor
    func testIntentIsConsumedBeforeReaderObserverCanReenter() throws {
        var reads = 0
        var repeated: Bool?
        var intent: RecoveryRevealIntent?
        weak var coordinator: RecoveryCoordinator?
        let reader = RecoveryEventReader(onRead: {
            reads += 1
            if reads == 1, let intent { repeated = coordinator?.reveal(intent) }
        })
        let fixture = try RecoveryTestFixture(eventReader: reader)
        coordinator = fixture.coordinator
        try fixture.adopt(fixture.begin())
        intent = try XCTUnwrap(fixture.coordinator.requestReveal())
        XCTAssertTrue(fixture.coordinator.reveal(try XCTUnwrap(intent)))
        XCTAssertEqual(repeated, false)
        XCTAssertEqual(reads, 1)
    }

    @MainActor
    func testHideDuringReaderCannotPublishEvenAfterImmediateShow() throws {
        for showAgain in [false, true] {
            var reads = 0
            weak var coordinator: RecoveryCoordinator?
            let reader = RecoveryEventReader(onRead: {
                reads += 1
                if reads == 1 {
                    coordinator?.hide()
                    if showAgain { coordinator?.show() }
                }
            })
            let fixture = try RecoveryTestFixture(eventReader: reader)
            coordinator = fixture.coordinator
            let hold = try fixture.begin()
            XCTAssertEqual(try hold.append(), .accepted)
            try fixture.adopt(hold)
            let intent = try XCTUnwrap(fixture.coordinator.requestReveal())
            XCTAssertFalse(fixture.coordinator.reveal(intent))
            XCTAssertNil(fixture.coordinator.revealedProjection)
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 1)
            fixture.coordinator.show()
            XCTAssertTrue(fixture.coordinator.reveal(try XCTUnwrap(fixture.coordinator.requestReveal())))
            XCTAssertEqual(reads, 2)
        }
    }

    @MainActor
    func testDeletionDuringReaderDropsProjectionWithoutResurrectingPayload() throws {
        var reads = 0
        weak var coordinator: RecoveryCoordinator?
        let reader = RecoveryEventReader(onRead: {
            reads += 1
            if let intent = coordinator?.requestDeletion() {
                XCTAssertEqual(coordinator?.confirmDeletion(intent), .deleted)
            }
        })
        let fixture = try RecoveryTestFixture(eventReader: reader)
        coordinator = fixture.coordinator
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append(), .accepted)
        try fixture.adopt(hold)
        XCTAssertFalse(fixture.coordinator.reveal(try XCTUnwrap(fixture.coordinator.requestReveal())))
        XCTAssertEqual(reads, 1)
        XCTAssertNil(fixture.coordinator.revealedProjection)
        XCTAssertEqual(fixture.coordinator.metadata?.payloadDeleted, true)
        XCTAssertNil(fixture.coordinator.requestReveal())
    }

    @MainActor
    func testOlderRevealDoesNotOverwriteNewerExplicitReveal() throws {
        var reads = 0
        var newerAccepted = false
        weak var coordinator: RecoveryCoordinator?
        let reader = RecoveryEventReader(onRead: {
            reads += 1
            if reads == 1, let fresh = coordinator?.requestReveal() {
                newerAccepted = coordinator?.reveal(fresh) == true
            }
        })
        let fixture = try RecoveryTestFixture(eventReader: reader)
        coordinator = fixture.coordinator
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append("saved"), .accepted)
        let identifier = try fixture.adopt(hold)
        let old = try XCTUnwrap(fixture.coordinator.requestReveal())
        XCTAssertFalse(fixture.coordinator.reveal(old))
        XCTAssertTrue(newerAccepted)
        XCTAssertEqual(reads, 2)
        try assertProjection(fixture.coordinator, record: identifier, fragments: ["saved"])
    }

    @MainActor
    func testReaderBudgetFailureIsExplicitAndDoesNotDeleteOriginalEvents() throws {
        var reads = 0
        let reader = RecoveryEventReader(onRead: { reads += 1 }, limits: .init(maximumEvents: 1))
        let fixture = try RecoveryTestFixture(eventReader: reader)
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append("a"), .accepted)
        XCTAssertEqual(try hold.append("b"), .accepted)
        let identifier = try fixture.adopt(hold)
        XCTAssertTrue(fixture.coordinator.reveal(try XCTUnwrap(fixture.coordinator.requestReveal())))
        let projection = try XCTUnwrap(fixture.coordinator.revealedProjection)
        XCTAssertEqual(projection.recordIdentifier, identifier)
        XCTAssertEqual(projection.failure, .eventLimitExceeded)
        XCTAssertTrue(projection.entries.isEmpty)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(fixture.coordinator.metadata?.eventCount, 2)
        XCTAssertEqual(fixture.coordinator.metadata?.payloadDeleted, false)
    }

    @MainActor
    func testExplicitRevealRemainsAvailableWhileInterceptionAndPermissionsAreOff() throws {
        var reads = 0
        let fixture = try RecoveryTestFixture(eventReader: RecoveryEventReader(onRead: { reads += 1 }))
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append("saved"), .accepted)
        let identifier = try fixture.adopt(hold)
        fixture.coordinator.setEnabled(false)
        fixture.coordinator.permissionsLost()
        fixture.coordinator.secureInputBegan()
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(fixture.coordinator.reveal(try XCTUnwrap(fixture.coordinator.requestReveal())))
        XCTAssertEqual(reads, 1)
        try assertProjection(fixture.coordinator, record: identifier, fragments: ["saved"])
        XCTAssertEqual(fixture.coordinator.metadata?.protection, .interceptionOff)
    }

    @MainActor
    func testDeletingAlreadyRevealedPayloadClearsCachedProjection() throws {
        var reads = 0
        let fixture = try RecoveryTestFixture(eventReader: RecoveryEventReader(onRead: { reads += 1 }))
        let hold = try fixture.begin()
        XCTAssertEqual(try hold.append(), .accepted)
        try fixture.adopt(hold)
        let reveal = try XCTUnwrap(fixture.coordinator.requestReveal())
        XCTAssertTrue(fixture.coordinator.reveal(reveal))
        XCTAssertNotNil(fixture.coordinator.revealedProjection)
        let deletion = try XCTUnwrap(fixture.coordinator.requestDeletion())
        XCTAssertEqual(fixture.coordinator.confirmDeletion(deletion), .deleted)
        XCTAssertNil(fixture.coordinator.revealedProjection)
        XCTAssertFalse(fixture.coordinator.reveal(reveal))
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(fixture.coordinator.hasPendingRecovery)
    }

    @MainActor
    private func assertProjection(_ coordinator: RecoveryCoordinator, record: UUID, fragments: [String]) throws {
        let projection = try XCTUnwrap(coordinator.revealedProjection)
        XCTAssertEqual(projection.recordIdentifier, record)
        XCTAssertNil(projection.failure)
        XCTAssertEqual(projection.entries.count, fragments.count)
        for (index, entry) in projection.entries.enumerated() where index < fragments.count {
            guard case .unicodeFragment(let fragment) = entry.content else {
                XCTFail("Ожидался точный payload события, а не результат редактирования"); continue
            }
            XCTAssertTrue(fragment.text.utf16.elementsEqual(fragments[index].utf16))
            XCTAssertEqual(fragment.evidence, .eventPayloadOnly)
        }
    }
}
