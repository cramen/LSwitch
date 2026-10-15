@testable import LSwitchCore
import XCTest

#if DEBUG
final class CommandUnicodeDiagnosticsTests: XCTestCase {
    func testKnownCommandLettersAreClassifiedWithoutReturningTheirContents() {
        for (command, latin, mapped) in [(ClipboardCommand.copy, "c", "с"), (.paste, "v", "м")] {
            XCTAssertEqual(CommandUnicodeDiagnostics.category(units: Array(latin.utf16), command: command), .latin)
            XCTAssertEqual(CommandUnicodeDiagnostics.category(units: Array(mapped.utf16), command: command), .mapped)
            XCTAssertEqual(
                CommandUnicodeDiagnostics.category(units: Array(mapped.uppercased().utf16), command: command), .mapped
            )
            XCTAssertEqual(CommandUnicodeDiagnostics.category(units: [], command: command), .empty)
            XCTAssertEqual(CommandUnicodeDiagnostics.category(units: [0xD83D, 0xDE00], command: command), .other)
        }
    }

    func testOtherCommandsDoNotEnterTheUnicodeDiagnosticPath() {
        for command in [ClipboardCommand.selectWord, .selectCharacters(1), .collapseSelection] {
            XCTAssertNil(CommandUnicodeDiagnostics.category(units: Array("fixture".utf16), command: command))
        }
    }
}
#endif
