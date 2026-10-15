import Foundation
@testable import LSwitchCore
import XCTest

final class UnicodePolicyTests: XCTestCase {
    func testExplicitAlphabetsPunctuationAndExactPacketBudget() {
        XCTAssertTrue(UnicodePacketPolicy.permits("АяЁё abcXYZ019 !\"#$%&'()*+,-./:;"))
        XCTAssertTrue(UnicodePacketPolicy.permits("<=>?@[\\]^_`{|}~"))
        XCTAssertTrue(UnicodePacketPolicy.permits("привет\u{00a0}"))
        XCTAssertTrue(UnicodePacketPolicy.permits(String(repeating: "я", count: 32)))
        XCTAssertFalse(UnicodePacketPolicy.permits(String(repeating: "я", count: 33)))
        XCTAssertFalse(UnicodePacketPolicy.permits(""))
    }

    func testControlsOtherBMPAndSurrogatesAreRejectedWithoutNormalization() {
        for value in ["\0", "\n", "\r", "\t", "\u{7F}", "é", "e\u{301}", "א", "\u{202E}", "😀"] {
            XCTAssertFalse(UnicodePacketPolicy.permits(value), value)
        }
        XCTAssertFalse(UnicodePacketPolicy.permits(units: [0xD800]))
        XCTAssertFalse(UnicodePacketPolicy.permits(units: [0xDC00]))
        XCTAssertFalse(UnicodePacketPolicy.permits(units: [0xD83D, 0xDE00]))
    }

    func testDirectSourceAllowlistDoesNotAcceptIMEOrExtendedLayout() {
        XCTAssertEqual(UnicodeInputSource(identifier: "com.apple.keylayout.ABC", isKeyboardLayout: true)?.layout,
                       .english)
        XCTAssertEqual(UnicodeInputSource(identifier: "com.apple.keylayout.Russian", isKeyboardLayout: true)?.layout,
                       .russian)
        XCTAssertNil(UnicodeInputSource(identifier: "com.apple.keylayout.ABC", isKeyboardLayout: false))
        XCTAssertNil(UnicodeInputSource(identifier: "com.apple.keylayout.ABCExtended", isKeyboardLayout: true))
        XCTAssertNil(UnicodeInputSource(identifier: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
                                       isKeyboardLayout: false))
    }

    func testSelectionRequiresGraphemeBoundaryAndLTRParagraph() {
        XCTAssertTrue(UnicodePacketPolicy.permitsSelection(in: "😀 ghbdtn ", range: NSRange(location: 3, length: 7)))
        XCTAssertFalse(UnicodePacketPolicy.permitsSelection(in: "x\u{301}", range: NSRange(location: 0, length: 1)))
        XCTAssertFalse(UnicodePacketPolicy.permitsSelection(in: "א ghbdtn ", range: NSRange(location: 2, length: 7)))
        XCTAssertFalse(UnicodePacketPolicy.permitsSelection(in: "abc", range: NSRange(location: 2, length: 9)))
    }

    func testCountEqualityDoesNotAuthorizeUnknownProvider() {
        let text = "done\"; int ghbdtn "
        let state = UnicodeTextSnapshot(text: text, selection: NSRange(location: text.utf16.count, length: 0),
                                        characterCount: text.utf16.count, coordinateText: text, provenance: .unverified)
        XCTAssertFalse(state.isComplete)
    }
}
