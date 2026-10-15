@testable import LSwitchCore
import XCTest

final class AutomaticDocumentPolicyTests: XCTestCase {
    func testSupportedDocumentRequiresFileMetadataAndActualTextRole() {
        XCTAssertEqual(context(document: "file:///tmp/check.swift"), .source(
            language: .swift, document: "file:///tmp/check.swift", characterCount: 10
        ))
        XCTAssertEqual(context(document: "file:///tmp/check.py"), .source(
            language: .python, document: "file:///tmp/check.py", characterCount: 10
        ))
        XCTAssertEqual(context(role: "AXGroup", document: "file:///tmp/check.swift"), .unknown)
        XCTAssertEqual(context(document: "https://example.test/check.swift"), .unknown)
    }

    func testEditorNameAloneDoesNotPretendToIdentifyCodeOrProse() {
        for bundleID in ["com.microsoft.VSCode", "com.apple.TextEdit", "ru.gigaide.ce"] {
            XCTAssertEqual(context(bundleID: bundleID), .unknown)
        }
        XCTAssertEqual(context(bundleID: "com.microsoft.VSCode", role: "AXTextField"), .prose)
        XCTAssertEqual(context(bundleID: "example.Chat"), .prose)
    }

    func testBrowserLocalPageDoesNotMakeItsTextareaCode() {
        for bundleID in ["com.apple.Safari", "com.google.Chrome"] {
            XCTAssertEqual(context(bundleID: bundleID, document: "file:///tmp/fixture.html"), .prose)
            XCTAssertEqual(context(bundleID: bundleID, document: "file:///tmp/fixture.js"), .prose)
        }
    }

    func testPlainDocumentIsProseAndUnsupportedSourceIsUnknown() {
        for fileExtension in ["txt", "md", "rtf"] {
            let document = "file:///tmp/check." + fileExtension
            XCTAssertEqual(context(document: document), .documentProse(document: document))
        }
        for fileExtension in ["rs", "go", "html", "unknown"] {
            XCTAssertEqual(context(document: "file:///tmp/check." + fileExtension), .unknown)
        }
    }

    func testOnlyConfirmedUntitledTextEditDocumentAllowsProse() {
        XCTAssertEqual(AutomaticDocumentPolicy.context(
            bundleID: "com.apple.TextEdit", role: "AXTextArea", document: nil, characterCount: nil,
            untitledDocumentIdentity: "untitled:100:1"
        ), .documentProse(document: "untitled:100:1"))
        XCTAssertEqual(AutomaticDocumentPolicy.context(
            bundleID: "com.microsoft.VSCode", role: "AXTextArea", document: nil, characterCount: nil,
            untitledDocumentIdentity: "untitled:100:1"
        ), .unknown)
    }

    private func context(
        bundleID: String = "com.microsoft.VSCode", role: String = "AXTextArea", document: String? = nil
    ) -> AutomaticTextContext {
        AutomaticDocumentPolicy.context(bundleID: bundleID, role: role, document: document, characterCount: 10)
    }
}
