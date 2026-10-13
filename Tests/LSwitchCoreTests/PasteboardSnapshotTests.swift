import AppKit
import XCTest
@testable import LSwitchCore

final class PasteboardSnapshotTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        pasteboard = try XCTUnwrap(
            NSPasteboard(name: NSPasteboard.Name("lswitch.test.\(UUID().uuidString)")),
            "Не удалось создать тестовый pasteboard"
        )
    }

    private func fillPasteboard() {
        pasteboard.clearContents()

        let textItem = NSPasteboardItem()
        textItem.setString("пример текста", forType: .string)
        textItem.setData(Data("rtf-body".utf8), forType: .rtf)
        pasteboard.writeObjects([textItem])

        let imageItem = NSPasteboardItem()
        imageItem.setData(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), forType: .png)
        pasteboard.writeObjects([imageItem])
    }

    func testFingerprintChangesWithContent() {
        fillPasteboard()
        let first = PasteboardService.fingerprint(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("другое", forType: .string)
        let second = PasteboardService.fingerprint(of: pasteboard)
        XCTAssertNotEqual(first, second)
    }

    func testFingerprintStableForSameContent() {
        fillPasteboard()
        XCTAssertEqual(
            PasteboardService.fingerprint(of: pasteboard),
            PasteboardService.fingerprint(of: pasteboard)
        )
    }

    func testSnapshotRoundTripRestoresIdenticalContent() {
        fillPasteboard()
        let snapshot = PasteboardService.capture(from: pasteboard)
        let before = PasteboardService.fingerprint(of: pasteboard)
        XCTAssertFalse(snapshot.items.isEmpty)

        // Портим буфер, как это делает clipboard-конвертер.
        pasteboard.clearContents()
        pasteboard.setString("сконвертированный текст", forType: .string)
        XCTAssertNotEqual(PasteboardService.fingerprint(of: pasteboard), before)

        PasteboardService.restore(snapshot, to: pasteboard)
        XCTAssertEqual(PasteboardService.fingerprint(of: pasteboard), before)
        XCTAssertEqual(pasteboard.string(forType: .string), "пример текста")
    }

    func testSnapshotCapturesAllTypes() {
        fillPasteboard()
        let snapshot = PasteboardService.capture(from: pasteboard)
        let allTypes = Set(snapshot.items.flatMap { $0.dataByType.keys })
        XCTAssertTrue(allTypes.contains(NSPasteboard.PasteboardType.string.rawValue))
        XCTAssertTrue(allTypes.contains(NSPasteboard.PasteboardType.rtf.rawValue))
        XCTAssertTrue(allTypes.contains(NSPasteboard.PasteboardType.png.rawValue))
    }
}
