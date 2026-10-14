import AppKit
@testable import LSwitchCore
import XCTest

final class PasteboardSnapshotTests: XCTestCase {
    @MainActor
    func testSnapshotRoundTripRestoresAllItemsTypesAndExactData() async throws {
        let fixture = try PasteboardFixture()
        defer { fixture.close() }
        fixture.fill()
        let snapshot = PasteboardService.capture(from: fixture.board)
        let fingerprint = PasteboardService.fingerprint(of: fixture.board)
        XCTAssertEqual(snapshot.items.count, 4)
        XCTAssertTrue(Set([
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.rtf.rawValue,
            PasteboardFixture.customType.rawValue
        ]).isSubset(of: Set(snapshot.items[0].dataByType.keys)))
        fixture.board.clearContents()
        XCTAssertTrue(fixture.board.setString("преобразованный текст", forType: .string))
        PasteboardService.restore(snapshot, to: fixture.board)
        XCTAssertEqual(PasteboardService.capture(from: fixture.board), snapshot)
        XCTAssertEqual(PasteboardService.fingerprint(of: fixture.board), fingerprint)
        XCTAssertEqual(fixture.board.pasteboardItems?.count, 4)
    }

    @MainActor
    func testRestoredRTFIsReadableAndPreservesOriginalBytes() async throws {
        let fixture = try PasteboardFixture()
        defer { fixture.close() }
        fixture.fillAndRoundTrip()
        // Общий data(forType:) объединяет текст нескольких items; проверяем исходный item.
        let item = try XCTUnwrap(fixture.board.pasteboardItems?.first)
        let data = try XCTUnwrap(item.data(forType: .rtf))
        XCTAssertEqual(data, fixture.rtf)
        let decoded = try NSAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil
        )
        XCTAssertEqual(decoded.string, PasteboardFixture.text)
        XCTAssertNotNil(decoded.attribute(.font, at: 0, effectiveRange: nil))
    }

    @MainActor
    func testRestoredPNGDecodesToRealPixels() async throws {
        let fixture = try PasteboardFixture()
        defer { fixture.close() }
        fixture.fillAndRoundTrip()
        let items = try XCTUnwrap(fixture.board.pasteboardItems)
        let data = try XCTUnwrap(items[1].data(forType: .png))
        XCTAssertEqual(data, fixture.png)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(decoded.pixelsWide, 2)
        XCTAssertEqual(decoded.pixelsHigh, 2)
        XCTAssertEqual(decoded.samplesPerPixel, 4)
        var pixel = [Int](repeating: 0, count: 4)
        decoded.getPixel(&pixel, atX: 0, y: 0)
        XCTAssertEqual(pixel, [255, 0, 0, 255])
    }

    @MainActor
    func testRestoredFileURLsResolveToOriginalFilesInOrder() async throws {
        let fixture = try PasteboardFixture()
        defer { fixture.close() }
        fixture.fillAndRoundTrip()
        let objects = try XCTUnwrap(fixture.board.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])
        XCTAssertEqual(objects, fixture.files)
        XCTAssertEqual(try Data(contentsOf: objects[0]), fixture.fileText)
        XCTAssertEqual(try Data(contentsOf: objects[1]), fixture.png)
    }

    @MainActor
    func testFingerprintStableForSameItemsRegardlessOfTypeDeclarationOrder() async throws {
        let fixture = try PasteboardFixture()
        defer { fixture.close() }
        let first = NSPasteboardItem()
        first.setString("same", forType: .string)
        first.setData(fixture.rtf, forType: .rtf)
        fixture.replace(with: [first])
        let expected = PasteboardService.fingerprint(of: fixture.board)
        let reversed = NSPasteboardItem()
        reversed.setData(fixture.rtf, forType: .rtf)
        reversed.setString("same", forType: .string)
        fixture.replace(with: [reversed])
        XCTAssertEqual(PasteboardService.fingerprint(of: fixture.board), expected)
    }

    @MainActor
    func testFingerprintIncludesItemOrderAndData() async throws {
        let fixture = try PasteboardFixture()
        defer { fixture.close() }
        fixture.replace(with: [textItem("first"), textItem("second")])
        let expected = PasteboardService.fingerprint(of: fixture.board)
        fixture.replace(with: [textItem("second"), textItem("first")])
        XCTAssertNotEqual(PasteboardService.fingerprint(of: fixture.board), expected)
        fixture.replace(with: [textItem("first"), textItem("changed")])
        XCTAssertNotEqual(PasteboardService.fingerprint(of: fixture.board), expected)
    }

    @MainActor
    func testFingerprintDistinguishesTypeDataBoundary() async throws {
        let fixture = try PasteboardFixture()
        defer { fixture.close() }
        let first = NSPasteboardItem()
        first.setData(Data("bc".utf8), forType: .init("org.lswitch.a"))
        fixture.replace(with: [first])
        let firstFingerprint = PasteboardService.fingerprint(of: fixture.board)
        let second = NSPasteboardItem()
        second.setData(Data("c".utf8), forType: .init("org.lswitch.ab"))
        fixture.replace(with: [second])
        XCTAssertNotEqual(PasteboardService.fingerprint(of: fixture.board), firstFingerprint)
    }

    @MainActor
    func testEmptyPasteboardRoundTripClearsTemporaryContent() async throws {
        let fixture = try PasteboardFixture()
        defer { fixture.close() }
        fixture.board.clearContents()
        let snapshot = PasteboardService.capture(from: fixture.board)
        let fingerprint = PasteboardService.fingerprint(of: fixture.board)
        fixture.board.setString("temporary", forType: .string)
        PasteboardService.restore(snapshot, to: fixture.board)
        XCTAssertEqual(PasteboardService.capture(from: fixture.board), snapshot)
        XCTAssertEqual(PasteboardService.fingerprint(of: fixture.board), fingerprint)
        XCTAssertTrue(fixture.board.pasteboardItems?.isEmpty ?? true)
    }

    @MainActor
    func testActualClipboardTransactionRestoresMixedFixture() async throws {
        let fixture = try PasteboardFixture()
        defer { fixture.close() }
        fixture.fill()
        let snapshot = PasteboardService.capture(from: fixture.board)
        let fingerprint = PasteboardService.fingerprint(of: fixture.board)
        let editor = PasteboardConversionEditor(board: fixture.board)
        let result = await editor.convert()
        XCTAssertEqual(result, .success(ConversionReceipt(original: "ghbdtn", converted: "привет")))
        XCTAssertEqual(editor.text, "привет")
        XCTAssertEqual(PasteboardService.capture(from: fixture.board), snapshot)
        XCTAssertEqual(PasteboardService.fingerprint(of: fixture.board), fingerprint)
    }

    @MainActor
    func testForeignFileURLCopyIsNotOverwrittenByTransactionRestore() async throws {
        let fixture = try PasteboardFixture()
        defer { fixture.close() }
        fixture.fill()
        let editor = PasteboardConversionEditor(board: fixture.board)
        editor.afterWrite = {
            fixture.board.clearContents()
            XCTAssertTrue(fixture.board.writeObjects([fixture.files[0] as NSURL]))
        }
        let result = await editor.convert()
        XCTAssertEqual(result, .blocked)
        XCTAssertEqual(editor.text, "ghbdtn")
        XCTAssertEqual(editor.selectionWrites, 0)
        let files = try XCTUnwrap(fixture.board.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])
        XCTAssertEqual(files, [fixture.files[0]])
        XCTAssertEqual(try Data(contentsOf: files[0]), fixture.fileText)
    }

    private func textItem(_ text: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        return item
    }
}

/// Только частный именованный pasteboard и временные файлы; general не изменяется.
@MainActor
private final class PasteboardFixture {
    static let text = "пример текста 🙂"
    static let customType = NSPasteboard.PasteboardType("org.lswitch.test.payload")
    let board = NSPasteboard(name: .init("lswitch.fixture.\(UUID().uuidString)"))
    let directory: URL
    let rtf: Data
    let png: Data
    let fileText = Data("содержимое файла\n".utf8)
    let files: [URL]

    init() throws {
        let attributed = NSAttributedString(string: Self.text, attributes: [.font: NSFont.boldSystemFont(ofSize: 16)])
        rtf = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        let pixels = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [0, 0, 0, 0]]
        for (index, components) in pixels.enumerated() {
            var pixel = components
            bitmap.setPixel(&pixel, atX: index % 2, y: index / 2)
        }
        png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lswitch-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        files = [directory.appendingPathComponent("пример файла.txt"), directory.appendingPathComponent("pixel.png")]
        try fileText.write(to: files[0])
        try png.write(to: files[1])
    }

    func close() {
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }

    func replace(with items: [NSPasteboardWriting]) {
        board.clearContents()
        XCTAssertTrue(board.writeObjects(items))
    }

    func fill() {
        let text = NSPasteboardItem()
        text.setString(Self.text, forType: .string)
        text.setData(rtf, forType: .rtf)
        text.setData(Data([0, 255, 17, 0]), forType: Self.customType)
        let image = NSPasteboardItem()
        image.setData(png, forType: .png)
        let fileItems = files.map { file -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(file.absoluteString, forType: .fileURL)
            item.setString(file.lastPathComponent, forType: .string)
            return item
        }
        replace(with: [text, image] + fileItems)
    }

    func fillAndRoundTrip() {
        fill()
        let snapshot = PasteboardService.capture(from: board)
        board.clearContents()
        board.setString("temporary", forType: .string)
        PasteboardService.restore(snapshot, to: board)
    }
}

/// Проверяет настоящее восстановление pasteboard через транзакцию; редактор остаётся чистым мок-объектом.
@MainActor
private final class PasteboardConversionEditor {
    let board: NSPasteboard
    var text = "ghbdtn"
    var selection = NSRange(location: 6, length: 0)
    var selectionWrites = 0
    var afterWrite: () -> Void = {}

    init(board: NSPasteboard) { self.board = board }

    func convert() async -> ConversionResult {
        let environment = ClipboardEnvironment(
            captureContext: { ClipboardEnvironment.Context(
                isValid: { true }, selectedText: { (self.text as NSString).substring(with: self.selection) },
                readState: { (self.text, self.selection) }, setSelection: {
                    self.selectionWrites += 1
                    self.selection = $0
                    return true
                }
            ) },
            capture: { PasteboardService.capture(from: self.board) },
            restore: { PasteboardService.restore($0, to: self.board) },
            changeCount: { self.board.changeCount },
            string: { self.board.string(forType: .string) },
            write: {
                let ownedCount = self.board.clearContents()
                let success = self.board.setString($0, forType: .string)
                self.afterWrite()
                return (success, ownedCount)
            },
            send: { _, _ in false },
            commitPaste: { select, check, valid in
                guard select(), check(), valid(), let inserted = self.board.string(forType: .string) else {
                    return .failed
                }
                self.text = (self.text as NSString).replacingCharacters(in: self.selection, with: inserted)
                self.selection = NSRange(location: self.selection.location + inserted.utf16.count, length: 0)
                return .performed
            },
            sleep: { _ in }
        )
        return await ClipboardConverter(environment: environment).perform(ConversionRequest(expectedWord: "ghbdtn"))
    }
}
