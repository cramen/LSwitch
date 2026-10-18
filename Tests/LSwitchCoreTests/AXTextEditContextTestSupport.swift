import ApplicationServices
import Foundation
@testable import LSwitchCore
import XCTest

@MainActor
final class AXTextEditContextFixture {
    let element = AXUIElementCreateApplication(100)
    var window = AXUIElementCreateApplication(200)
    var elementPID: Int32? = 100
    var windowPID: Int32? = 100
    var process: RecoveryProcessIdentity?
    var application: AXProfileApplicationIdentity? = .init(
        bundleIdentifier: "com.apple.TextEdit", bundleURL: URL(fileURLWithPath: "/fixture/TextEdit.app")
    )
    var versions: AXProfileVersionMetadata? = .init(
        applicationVersion: "1.19", applicationBuild: "404", systemVersion: "14.5", systemBuild: "23F79"
    )
    var role = kAXTextAreaRole
    var elementDocument = AXProfileDocumentValue.missing
    var windowDocument = AXProfileDocumentValue.value("file:///fixture/first.txt")
    var metadataAvailable = true
    var processReads = 0
    var applicationReads = 0
    var versionReads = 0
    var batchReads = 0
    var windowDocumentReads = 0

    init() throws {
        process = try XCTUnwrap(RecoveryProcessIdentity(processID: 100, birthSeconds: 1, birthMicroseconds: 0))
    }

    func makeReader() -> AXTextEditContextReader {
        AXTextEditContextReader(access: .init(processID: { element in
            CFEqual(element, self.element) ? self.elementPID : self.windowPID
        }, processIdentity: { _ in
            self.processReads += 1
            return self.process
        }, application: { _ in
            self.applicationReads += 1
            return self.application
        }, versions: { _ in
            self.versionReads += 1
            return self.versions
        }, elementMetadata: { _ in
            self.batchReads += 1
            guard self.metadataAvailable else { return nil }
            return .init(role: self.role, window: self.window, document: self.elementDocument)
        }, windowDocument: { window in
            XCTAssertTrue(CFEqual(window, self.window))
            self.windowDocumentReads += 1
            return self.windowDocument
        }))
    }
}
