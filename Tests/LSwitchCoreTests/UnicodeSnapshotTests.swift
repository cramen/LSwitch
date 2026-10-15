import Foundation
@testable import LSwitchCore
import XCTest

final class UnicodeSnapshotTests: XCTestCase {
    func testExactProviderVersionAndEditableDocumentRootRequired() {
        XCTAssertTrue(provider())
        XCTAssertFalse(provider(version: "156.0.1"))
        XCTAssertFalse(provider(version: "155.0.8059.81"))
        XCTAssertFalse(provider(bundleID: "com.microsoft.VSCode"))
        XCTAssertFalse(provider(role: "AXStaticText"))
        XCTAssertFalse(provider(editableRoot: false))
        XCTAssertFalse(provider(documentRoot: false))
    }

    func testUTF8BoundaryRejectsPotentialTruncationIncludingMultibyteBackoff() {
        XCTAssertTrue(UnicodeSnapshotPolicy.permitsValue(String(repeating: "a", count: 9_996)))
        XCTAssertFalse(UnicodeSnapshotPolicy.permitsValue(String(repeating: "a", count: 9_997)))
        XCTAssertFalse(UnicodeSnapshotPolicy.permitsValue(String(repeating: "a", count: 10_000)))
        XCTAssertTrue(UnicodeSnapshotPolicy.permitsValue(String(repeating: "я", count: 4_998)))
        XCTAssertFalse(UnicodeSnapshotPolicy.permitsValue(String(repeating: "я", count: 4_999)))
        XCTAssertTrue(UnicodeSnapshotPolicy.permitsValue(String(repeating: "😀", count: 2_499)))
        XCTAssertFalse(UnicodeSnapshotPolicy.permitsValue(String(repeating: "😀", count: 2_500)))
    }

    func testRichParagraphMismatchCannotUseAXValueCoordinates() {
        XCTAssertFalse(snapshot(value: "A\nB\nC", coordinates: "ABC").isComplete)
        XCTAssertFalse(snapshot(value: "ABC", coordinates: nil).isComplete)
        XCTAssertTrue(snapshot(value: "ABC", coordinates: "ABC").isComplete)
    }

    func testCanonicalStringEqualityDoesNotReplaceExactUTF16Verification() {
        XCTAssertEqual("é", "e\u{301}")
        XCTAssertFalse(snapshot(value: "é", coordinates: "e\u{301}").isComplete)
        let state = snapshot(value: "é", coordinates: "é")
        XCTAssertFalse(state.matches(text: "e\u{301}", selection: state.selection))
    }

    private func provider(
        version: String = "155.0.8059.80", bundleID: String = "com.google.Chrome",
        role: String = "AXTextArea", editableRoot: Bool = true, documentRoot: Bool = true
    ) -> Bool {
        UnicodeSnapshotPolicy.permitsProvider(bundleID: bundleID, version: version, role: role,
                                             editableRoot: editableRoot, documentRoot: documentRoot)
    }

    private func snapshot(value: String, coordinates: String?) -> UnicodeTextSnapshot {
        UnicodeTextSnapshot(text: value, selection: NSRange(location: value.utf16.count, length: 0),
                            characterCount: value.utf16.count, coordinateText: coordinates,
                            provenance: .chromiumTextControl)
    }
}
