#if DEBUG
import Foundation
@testable import LSwitchCore
import XCTest

final class ConverterProfileUndoTests: XCTestCase {
    @MainActor
    func testTypedUndoUsesNewCombinedSessionAndRestoresExactNBSPAndDecomposedOriginal() async throws {
        let samples = ["ghbdtn\u{00a0}", "g\u{0301}\u{0323}hbdtn ", "цщкдв "]
        for original in samples {
            let fixture = try ProfileUndoConverterFixture(original)
            if original == "цщкдв " {
                fixture.layout = .russian
                fixture.editor.activeSource = .init(identifier: "com.apple.keylayout.Russian", isKeyboardLayout: true)
            }
            guard case .converted = try await fixture.perform() else { return XCTFail("Нужен conversion control") }
            XCTAssertNotNil(fixture.converter.undoProfileAnchor)
            let undone = try await fixture.perform()
            XCTAssertEqual(undone, .undone)
            XCTAssertTrue(fixture.editor.access.model.value.utf16.elementsEqual(original.utf16))
            XCTAssertEqual(fixture.editor.access.model.currentSelection,
                           NSRange(location: original.utf16.count, length: 0))
            XCTAssertNotNil(fixture.engines.last?.requests.first?.profileValidation?.undoTarget)
            XCTAssertFalse(fixture.sessions.first === fixture.sessions.last)
            XCTAssertEqual(fixture.editor.access.model.textWrites, 2)
            XCTAssertNil(fixture.undoStore.pendingUndo())
            XCTAssertNil(fixture.converter.undoProfileAnchor)
        }
    }

    @MainActor
    func testMovedCaretAtAnotherIdenticalWordRejectsTypedUndoBeforeSelection() async throws {
        let fixture = try ProfileUndoConverterFixture("привет ghbdtn")
        guard case .converted = try await fixture.perform() else { return XCTFail("Нужен conversion control") }
        fixture.editor.access.model.currentSelection = NSRange(location: 6, length: 0)
        let writes = fixture.editor.access.model.selectionWrites.count
        let result = try await fixture.perform()
        XCTAssertEqual(result, .recoveryRequired)
        XCTAssertEqual(fixture.editor.access.model.value, "привет привет")
        XCTAssertEqual(fixture.editor.access.model.selectionWrites.count, writes)
        XCTAssertEqual(fixture.editor.access.model.textWrites, 1)
        XCTAssertNotNil(fixture.engines.last?.requests.first?.profileValidation?.undoTarget)
    }

    @MainActor
    func testCanonicalEquivalentSpanAndChangedTailCannotPassExactUndoAtTheSameCaret() async throws {
        let samples = [("g\u{0301}\u{0323}hbdtn ", "g\u{0323}\u{0301}ривет "),
                       ("ghbdtn\u{00a0}", "привет ")]
        for (original, changed) in samples {
            let fixture = try ProfileUndoConverterFixture(original)
            guard case .converted = try await fixture.perform() else { return XCTFail("Нужен conversion control") }
            XCTAssertEqual(fixture.editor.access.model.value.utf16.count, changed.utf16.count)
            fixture.editor.access.model.value = changed
            let writes = fixture.editor.access.model.selectionWrites.count
            let result = try await fixture.perform()
            XCTAssertEqual(result, .recoveryRequired)
            XCTAssertEqual(fixture.editor.access.model.selectionWrites.count, writes)
            XCTAssertEqual(fixture.editor.access.model.textWrites, 1)
            XCTAssertTrue(fixture.editor.access.model.value.utf16.elementsEqual(changed.utf16))
        }
    }

    @MainActor
    func testOldDocumentAndCustomReceiptGuardAreStillCheckedWithoutTypedBypass() async throws {
        let foreign = try ProfileUndoConverterFixture("ghbdtn ")
        guard case .converted = try await foreign.perform() else { return XCTFail("Нужен conversion control") }
        foreign.editor.document = "fixture:other-document"
        let blocked = try await foreign.perform()
        XCTAssertEqual(blocked, .blockedBySafety)
        XCTAssertEqual(foreign.editor.access.model.textWrites, 1)
        XCTAssertTrue(foreign.engines.last?.requests.isEmpty == true)
        let custom = try ProfileUndoConverterFixture("ghbdtn ")
        var valid = true
        custom.customTarget = { valid }
        guard case .converted = try await custom.perform() else { return XCTFail("Нужен custom receipt control") }
        XCTAssertNil(custom.converter.undoProfileAnchor)
        custom.editor.duringRead = { _ in valid = false }
        let failed = try await custom.perform()
        XCTAssertEqual(failed, .recoveryRequired)
        XCTAssertNil(custom.engines.last?.requests.first?.profileValidation)
        XCTAssertEqual(custom.editor.access.model.textWrites, 1)
    }
}
#endif
