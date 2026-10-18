import ApplicationServices
import Foundation
@testable import LSwitchCore
import XCTest

final class AXBoundedSnapshotTests: XCTestCase {
    @MainActor
    func testConcreteReaderOwnsAllFiveBoundariesWithoutCallingArbitraryProvider() throws {
        let fixture = try AXProfileFixture()
        let operation = try prepare(fixture, bounded: access(fixture))
        let before = operation.profile.diagnosticReport.context.count
        XCTAssertNotNil(operation.profile.read(expected: nil, ledger: operation.ledger))
        XCTAssertEqual(operation.profile.diagnosticReport.context.count - before, 5)
        XCTAssertEqual(fixture.snapshotReads, 0)
        XCTAssertEqual(fixture.access.model.textReads, 1)
        XCTAssertEqual(fixture.access.model.selectionReads, 1)
    }

    @MainActor
    func testCountReentryChangingDocumentStopsBeforeTextPayload() throws {
        let fixture = try AXProfileFixture()
        let model = fixture.access.model
        let bounded = AXBoundedSnapshotAccess(count: { _ in
            fixture.document = "fixture:changed"
            return model.value.utf16.count
        }, text: { element, _ in model.text(in: element) }, selection: { model.selection(in: $0) })
        let operation = try prepare(fixture, bounded: bounded)
        XCTAssertNil(operation.profile.read(expected: nil, ledger: operation.ledger))
        XCTAssertEqual(model.textReads, 0)
        XCTAssertEqual(model.selectionReads, 0)
        XCTAssertTrue(operation.ledger.hasProfileFault)
        XCTAssertEqual(operation.ledger.submissionCount, 0)
    }

    @MainActor
    func testFinalSelectionReadBecomingProtectedCannotReturnOrHealSnapshot() throws {
        let fixture = try AXProfileFixture()
        let model = fixture.access.model
        let bounded = AXBoundedSnapshotAccess(count: { _ in model.value.utf16.count },
                                              text: { element, _ in model.text(in: element) }, selection: { element in
            let selection = model.selection(in: element)
            model.protected = true
            return selection
        })
        let operation = try prepare(fixture, bounded: bounded)
        XCTAssertNil(operation.profile.read(expected: nil, ledger: operation.ledger))
        XCTAssertEqual(model.textReads, 1)
        XCTAssertTrue(operation.ledger.hasProfileFault)
        model.protected = false
        XCTAssertNil(operation.profile.read(expected: nil, ledger: operation.ledger))
        XCTAssertEqual(model.textReads, 1)
    }

    @MainActor
    func testOversizedConcreteReadRefusesBeforePayloadAndDoesNotUseFallback() throws {
        let fixture = try AXProfileFixture()
        let model = fixture.access.model
        let bounded = AXBoundedSnapshotAccess(count: { _ in AXProfileSnapshot.maximumUTF16Units + 1 },
                                              text: { element, _ in model.text(in: element) },
                                              selection: { model.selection(in: $0) })
        let operation = try prepare(fixture, bounded: bounded)
        XCTAssertNil(operation.profile.read(expected: nil, ledger: operation.ledger))
        XCTAssertEqual(model.textReads, 0)
        XCTAssertEqual(fixture.snapshotReads, 0)
        XCTAssertTrue(operation.ledger.hasProfileFault)
    }

    @MainActor
    private func access(_ fixture: AXProfileFixture) -> AXBoundedSnapshotAccess {
        let model = fixture.access.model
        return .init(count: { _ in model.value.utf16.count }, text: { element, range in
            XCTAssertEqual(range, NSRange(location: 0, length: model.value.utf16.count))
            return model.text(in: element)
        }, selection: { model.selection(in: $0) })
    }

    @MainActor
    private func prepare(
        _ fixture: AXProfileFixture, bounded: AXBoundedSnapshotAccess
    ) throws -> AXProfileTestOperation {
        var environment = fixture.environment
        environment.boundedSnapshot = bounded
        let profile = try XCTUnwrap(AXObservationProfile.prepareTextEdit(
            element: fixture.access.model.element, environment: environment))
        let ledger = ConversionSafetyLedger(generation: 1, profile: profile.binding)
        XCTAssertTrue(profile.bind(to: fixture.access.model.element, ledger: ledger, isValid: { fixture.valid }))
        return .init(profile: profile, ledger: ledger,
                     converter: AXTextConverter(access: fixture.access, observationProfile: profile))
    }
}
