import ApplicationServices
import Foundation
@testable import LSwitchCore
import XCTest

final class AXTextEditContextTests: XCTestCase {
    @MainActor
    func testOnlyVersionsAreCachedWhileEveryContextReadsFreshProcessBatchAndWindowDocument() throws {
        let fixture = try AXTextEditContextFixture()
        let reader = fixture.makeReader()
        for _ in 0..<5 { XCTAssertTrue(try XCTUnwrap(reader.context(fixture.element)).isSupported) }
        XCTAssertEqual(fixture.versionReads, 1)
        XCTAssertEqual(fixture.processReads, 5)
        XCTAssertEqual(fixture.applicationReads, 5)
        XCTAssertEqual(fixture.batchReads, 5)
        XCTAssertEqual(fixture.windowDocumentReads, 5)
    }

    @MainActor
    func testWindowDocumentAndRoleChangesRemainFreshWithWarmVersionCache() throws {
        let fixture = try AXTextEditContextFixture()
        let reader = fixture.makeReader()
        let original = try XCTUnwrap(reader.context(fixture.element))
        fixture.windowDocument = .value("file:///fixture/second.txt")
        XCTAssertFalse(original.matches(try XCTUnwrap(reader.context(fixture.element))))
        fixture.windowDocument = .value(original.document)
        fixture.window = AXUIElementCreateApplication(201)
        XCTAssertFalse(original.matches(try XCTUnwrap(reader.context(fixture.element))))
        fixture.role = kAXButtonRole
        XCTAssertNil(reader.context(fixture.element))
        XCTAssertEqual(fixture.versionReads, 1)
    }

    @MainActor
    func testForeignOrUnknownWindowPIDRefusesBeforeReadingItsDocument() throws {
        for foreign: Int32? in [101, nil] {
            let fixture = try AXTextEditContextFixture()
            let reader = fixture.makeReader()
            fixture.windowPID = foreign
            XCTAssertNil(reader.context(fixture.element))
            XCTAssertEqual(fixture.windowDocumentReads, 0)
        }
    }

    @MainActor
    func testOnlyExplicitMissingWindowDocumentCreatesUntitledIdentity() throws {
        let fixture = try AXTextEditContextFixture()
        let reader = fixture.makeReader()
        fixture.windowDocument = .missing
        let untitled = try XCTUnwrap(reader.context(fixture.element))
        XCTAssertEqual(untitled.document, "untitled:100:\(CFHash(fixture.window))")
        for document in [AXProfileDocumentValue.unavailable, .value("https://example.invalid/"), .value("invalid")] {
            fixture.windowDocument = document
            XCTAssertNil(reader.context(fixture.element))
        }
    }

    @MainActor
    func testElementDocumentPreferenceAndWindowFallbackPreserveExistingIdentitySemantics() throws {
        let fixture = try AXTextEditContextFixture()
        let reader = fixture.makeReader()
        fixture.elementDocument = .value("file:///fixture/element.txt")
        fixture.windowDocument = .unavailable
        XCTAssertEqual(reader.context(fixture.element)?.document, "file:///fixture/element.txt")
        XCTAssertEqual(fixture.windowDocumentReads, 0)
        fixture.windowDocument = .value("file:///fixture/window.txt")
        for document in [AXProfileDocumentValue.missing, .unavailable, .value("invalid")] {
            fixture.elementDocument = document
            XCTAssertEqual(reader.context(fixture.element)?.document, "file:///fixture/window.txt")
        }
        XCTAssertEqual(fixture.windowDocumentReads, 3)
    }

    @MainActor
    func testBirthPIDAndBundleURLChangesInvalidateVersionCache() throws {
        let fixture = try AXTextEditContextFixture()
        let reader = fixture.makeReader()
        XCTAssertNotNil(reader.context(fixture.element))
        fixture.process = RecoveryProcessIdentity(processID: 100, birthSeconds: 2, birthMicroseconds: 0)
        XCTAssertNotNil(reader.context(fixture.element))
        XCTAssertEqual(fixture.versionReads, 2)
        fixture.process = RecoveryProcessIdentity(processID: 101, birthSeconds: 2, birthMicroseconds: 0)
        fixture.elementPID = 101
        fixture.windowPID = 101
        XCTAssertNotNil(reader.context(fixture.element))
        XCTAssertEqual(fixture.versionReads, 3)
        fixture.application = .init(bundleIdentifier: "com.apple.TextEdit",
                                    bundleURL: URL(fileURLWithPath: "/fixture/other/TextEdit.app"))
        fixture.versions = .init(applicationVersion: "1.20", applicationBuild: "405",
                                 systemVersion: "14.5", systemBuild: "23F79")
        XCTAssertFalse(try XCTUnwrap(reader.context(fixture.element)).isSupported)
        XCTAssertEqual(fixture.versionReads, 4)
    }

    @MainActor
    func testUnknownProcessOrApplicationAndForeignBundleClearCache() throws {
        let fixture = try AXTextEditContextFixture()
        let reader = fixture.makeReader()
        let process = fixture.process
        let application = fixture.application
        XCTAssertNotNil(reader.context(fixture.element))
        fixture.process = nil
        XCTAssertNil(reader.context(fixture.element))
        fixture.process = process
        XCTAssertNotNil(reader.context(fixture.element))
        fixture.application = nil
        XCTAssertNil(reader.context(fixture.element))
        fixture.application = application
        XCTAssertNotNil(reader.context(fixture.element))
        fixture.application = .init(bundleIdentifier: "other.app", bundleURL: try XCTUnwrap(application).bundleURL)
        XCTAssertNil(reader.context(fixture.element))
        fixture.application = application
        XCTAssertNotNil(reader.context(fixture.element))
        XCTAssertEqual(fixture.versionReads, 4)
    }

    @MainActor
    func testFailedVersionReadIsNotCachedAndMismatchedProcessNeverLoadsVersions() throws {
        let fixture = try AXTextEditContextFixture()
        let reader = fixture.makeReader()
        let versions = fixture.versions
        fixture.versions = nil
        XCTAssertNil(reader.context(fixture.element))
        fixture.versions = versions
        XCTAssertNotNil(reader.context(fixture.element))
        XCTAssertEqual(fixture.versionReads, 2)
        fixture.process = RecoveryProcessIdentity(processID: 101, birthSeconds: 1, birthMicroseconds: 0)
        XCTAssertNil(reader.context(fixture.element))
        XCTAssertEqual(fixture.versionReads, 2)
    }

    @MainActor
    func testWarmCacheDoesNotHideDocumentSwitchBeforeRealProfileConversion() async throws {
        let model = try AXProfileFixture()
        let fixture = try AXTextEditContextFixture()
        let reader = fixture.makeReader()
        let original = model.environment
        let environment = AXProfileEnvironment(
            activeSource: original.activeSource, focusedElement: original.focusedElement,
            isProtected: original.isProtected, context: { reader.context($0) }, snapshot: original.snapshot
        )
        let profile = try XCTUnwrap(AXObservationProfile.prepareTextEdit(
            element: model.access.model.element, environment: environment
        ))
        let ledger = ConversionSafetyLedger(generation: 1, profile: profile.binding)
        let converter = AXTextConverter(access: model.access, observationProfile: profile)
        fixture.windowDocument = .value("file:///fixture/reused-tab.txt")
        let result = await converter.performWithEvidence(model.request(ledger))
        XCTAssertEqual(result.result, .blocked)
        XCTAssertTrue(ledger.hasProfileFault)
        XCTAssertEqual(model.snapshotReads, 0)
        XCTAssertEqual(model.access.model.textWrites, 0)
        XCTAssertTrue(model.access.model.selectionWrites.isEmpty)
        XCTAssertEqual(fixture.versionReads, 1)
    }
}
