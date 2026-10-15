import AppKit
import Foundation
import LSwitchCore

private final class AcceptanceDataProvider: NSObject, NSPasteboardItemDataProvider {
    let values: [NSPasteboard.PasteboardType: Data]
    private let lock = NSLock()
    private var requested: [String] = []
    private var finished = false

    init(values: [NSPasteboard.PasteboardType: Data]) { self.values = values }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    var didFinish: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        lock.lock()
        requested.append(type.rawValue)
        lock.unlock()
        if let value = values[type] { item.setData(value, forType: type) }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

@MainActor
enum AcceptanceClipboardProbe {
    private struct Fixture {
        let plain: Data
        let rtf: Data
        let png: Data
        let files: [URL]

        init(at directory: URL) throws {
            plain = try Data(contentsOf: directory.appendingPathComponent("original.txt"))
            rtf = try Data(contentsOf: directory.appendingPathComponent("formatted.rtf"))
            png = try Data(contentsOf: directory.appendingPathComponent("pixels.png"))
            files = ["file-one.txt", "file-two.txt"].map { directory.appendingPathComponent($0) }
            for file in files { _ = try Data(contentsOf: file) }
        }
    }

    static func run(mode: String, fixtures: URL?) -> [String: Any] {
        let board = NSPasteboard(name: .init("ru.cramen.lswitch.probe.clipboard.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        if mode == "clipboard-unresolved" { return unresolved(board: board) }
        guard let fixtures else { return ["ok": false, "error": "fixtures-required"] }
        do {
            let fixture = try Fixture(at: fixtures)
            if mode == "clipboard-lazy" { return lazy(board: board, fixture: fixture) }
            return mixed(board: board, fixture: fixture)
        } catch {
            return ["ok": false, "error": "fixture-read: \(error.localizedDescription)"]
        }
    }

    private static func mixed(board: NSPasteboard, fixture: Fixture) -> [String: Any] {
        let text = NSPasteboardItem()
        let image = NSPasteboardItem()
        guard text.setData(fixture.plain, forType: .string), text.setData(fixture.rtf, forType: .rtf),
              image.setData(fixture.png, forType: .png) else { return ["ok": false, "error": "fixture-types"] }
        var objects: [NSPasteboardWriting] = [text, image]
        for file in fixture.files { objects.append(file as NSURL) }
        guard board.writeObjects(objects) else { return ["ok": false, "error": "private-board-write"] }
        let snapshot = PasteboardService.capture(from: board)
        let fingerprint = PasteboardService.fingerprint(of: board)
        guard snapshot.isRestorable else { return ["ok": false, "error": "mixed-not-restorable"] }
        board.clearContents()
        board.setString("Временный результат замены", forType: .string)
        let restored = PasteboardService.restore(snapshot, to: board)
        let identical = PasteboardService.capture(from: board) == snapshot
        let fingerprintMatches = PasteboardService.fingerprint(of: board) == fingerprint
        let decoded = decode(board: board, fixture: fixture)
        return ["ok": restored && identical && fingerprintMatches && decoded,
                "board": board.name.rawValue, "items": snapshot.items.count,
                "restored": restored, "snapshotEqual": identical, "fingerprintEqual": fingerprintMatches,
                "decodedRTFPNGFiles": decoded, "providerReceiverMatrixComplete": false]
    }

    private static func decode(board: NSPasteboard, fixture: Fixture) -> Bool {
        guard let items = board.pasteboardItems, items.count == 4,
              let rtf = items[0].data(forType: .rtf), let png = items[1].data(forType: .png),
              let rich = try? NSAttributedString(
                data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil
              ), let bitmap = NSBitmapImageRep(data: png), bitmap.pixelsWide == 2, bitmap.pixelsHigh == 2,
              rich.string == String(data: fixture.plain, encoding: .utf8),
              let urls = board.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
              ) as? [URL],
              urls == fixture.files else { return false }
        return zip(urls, fixture.files).allSatisfy { pair in
            (try? Data(contentsOf: pair.0)) == (try? Data(contentsOf: pair.1))
        }
    }

    private static func lazy(board: NSPasteboard, fixture: Fixture) -> [String: Any] {
        let provider = AcceptanceDataProvider(values: [.string: fixture.plain, .rtf: fixture.rtf])
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: [.string, .rtf]), board.writeObjects([item]) else {
            return ["ok": false, "error": "lazy-provider-write"]
        }
        let beforeCapture = provider.requests.count
        let snapshot = PasteboardService.capture(from: board)
        let afterCapture = provider.requests.count
        guard snapshot.isRestorable else { return ["ok": false, "error": "lazy-unmaterialized"] }
        board.clearContents()
        board.setString("Временный результат", forType: .string)
        let restored = PasteboardService.restore(snapshot, to: board)
        let identical = PasteboardService.capture(from: board) == snapshot
        return ["ok": restored && identical && afterCapture > beforeCapture,
                "requestsBeforeCapture": beforeCapture, "requestsAfterCapture": afterCapture,
                "requestedTypes": provider.requests, "restored": restored, "snapshotEqual": identical,
                "genuineFilePromise": false]
    }

    private static func unresolved(board: NSPasteboard) -> [String: Any] {
        let type = NSPasteboard.PasteboardType("ru.cramen.lswitch.probe.unresolved")
        let provider = AcceptanceDataProvider(values: [:])
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: [type]), board.writeObjects([item]) else {
            return ["ok": false, "error": "unresolved-provider-write"]
        }
        let snapshot = PasteboardService.capture(from: board)
        let declared = snapshot.items.first?.dataByType.keys.contains(type.rawValue) == true
        let count = board.changeCount
        let refused = !PasteboardService.restore(snapshot, to: board)
        let ownerPreserved = board.changeCount == count
        let beforeClear = provider.didFinish
        board.clearContents()
        let deadline = Date().addingTimeInterval(1)
        while !provider.didFinish && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let substitute = NSPasteboardItem()
        substitute.setString("", forType: type)
        let emptyHasData = substitute.data(forType: type) != nil
        return ["ok": declared && !snapshot.isRestorable && refused && ownerPreserved && emptyHasData,
                "declaredNilTypePreserved": declared, "isRestorable": snapshot.isRestorable,
                "restoreRefusedBeforeClear": refused && ownerPreserved, "legacyEmptyStringHasData": emptyHasData,
                "providerFinishedBeforeClear": beforeClear, "providerFinishedAfterClear": provider.didFinish,
                "privateDestructiveDemonstration": true, "genuineFilePromise": false]
    }
}
