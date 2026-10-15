import AppKit
@testable import LSwitchCore
import UniformTypeIdentifiers
import XCTest

private final class LazyBoardProvider: NSObject, NSPasteboardItemDataProvider {
    let payload: Data?
    private let lock = NSLock()
    private var requests = 0
    private var finished = false

    init(payload: Data?) { self.payload = payload }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
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
        requests += 1
        lock.unlock()
        if let payload { item.setData(payload, forType: type) }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        lock.lock()
        finished = true
        lock.unlock()
    }
}

private final class FilePromiseFixtureDelegate: NSObject, NSFilePromiseProviderDelegate {
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "lswitch-promised-file.txt"
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try Data("Файл создан обещанием, не готовым fileURL".utf8).write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

final class PasteboardProviderTests: XCTestCase {
    @MainActor
    private func makeBoard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("lswitch.provider.tests.\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    @MainActor
    func testMaterializedLazyProviderRestoresWithoutOriginalOwner() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let payload = Data("Ленивые данные 🙂".utf8)
        let provider = LazyBoardProvider(payload: payload)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.string]))
        XCTAssertTrue(board.writeObjects([item]))
        let snapshot = PasteboardService.capture(from: board)
        XCTAssertGreaterThan(provider.requestCount, 0)
        XCTAssertTrue(snapshot.isRestorable)
        board.clearContents()
        XCTAssertTrue(board.setString("временная запись", forType: .string))
        XCTAssertTrue(PasteboardService.restore(snapshot, to: board))
        XCTAssertEqual(board.pasteboardItems?.first?.data(forType: .string), payload)
        XCTAssertEqual(PasteboardService.capture(from: board), snapshot)
        withExtendedLifetime(provider) {}
    }

    @MainActor
    func testUnresolvedTypeRemainsExplicitNilAndRestoreDoesNotClearOwner() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let type = NSPasteboard.PasteboardType("ru.cramen.lswitch.tests.unresolved")
        let provider = LazyBoardProvider(payload: nil)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [type]))
        XCTAssertTrue(board.writeObjects([item]))
        let snapshot = PasteboardService.capture(from: board)
        let captured = try XCTUnwrap(snapshot.items.first)
        XCTAssertTrue(captured.dataByType.keys.contains(type.rawValue))
        XCTAssertNil(try XCTUnwrap(captured.dataByType[type.rawValue]))
        XCTAssertFalse(snapshot.isRestorable)
        let count = board.changeCount
        XCTAssertFalse(PasteboardService.restore(snapshot, to: board))
        XCTAssertEqual(board.changeCount, count)
        XCTAssertTrue(board.pasteboardItems?.first?.types.contains(type) == true)
        XCTAssertGreaterThan(provider.requestCount, 0)
    }

    @MainActor
    func testEmptyStringIsNotEquivalentToAnUnresolvedPromise() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let type = NSPasteboard.PasteboardType("ru.cramen.lswitch.tests.nil-versus-empty")
        let provider = LazyBoardProvider(payload: nil)
        let unresolved = NSPasteboardItem()
        XCTAssertTrue(unresolved.setDataProvider(provider, forTypes: [type]))
        XCTAssertTrue(board.writeObjects([unresolved]))
        XCTAssertNil(board.pasteboardItems?.first?.data(forType: type))
        // Воспроизводим прежнюю подмену только на частном pasteboard: тип остаётся, семантика теряется.
        board.clearContents()
        let substitute = NSPasteboardItem()
        XCTAssertTrue(substitute.setString("", forType: type))
        XCTAssertTrue(board.writeObjects([substitute]))
        XCTAssertNotNil(board.pasteboardItems?.first?.data(forType: type))
        withExtendedLifetime(provider) {}
    }

    @MainActor
    func testClearInvalidatesUnfulfilledProvider() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let provider = LazyBoardProvider(payload: nil)
        let item = NSPasteboardItem()
        let type = NSPasteboard.PasteboardType("ru.cramen.lswitch.tests.invalidated")
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [type]))
        XCTAssertTrue(board.writeObjects([item]))
        XCTAssertNil(board.pasteboardItems?.first?.data(forType: type))
        board.clearContents()
        let deadline = Date().addingTimeInterval(1)
        while !provider.didFinish && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(provider.didFinish, "После смены владельца provider уже нельзя считать доступным")
        XCTAssertNil(board.data(forType: type))
        withExtendedLifetime(item) {}
    }

    @MainActor
    func testPromiseInLaterItemRejectsBeforeReadingAnyProvidersData() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let provider = LazyBoardProvider(payload: Data("must not materialize".utf8))
        let ordinary = NSPasteboardItem()
        XCTAssertTrue(ordinary.setDataProvider(provider, forTypes: [.string]))
        let promiseType = try XCTUnwrap(NSFilePromiseReceiver.readableDraggedTypes.first)
        let promised = NSPasteboardItem()
        XCTAssertTrue(promised.setDataProvider(provider, forTypes: [.init(promiseType)]))
        XCTAssertTrue(board.writeObjects([ordinary, promised]))
        let snapshot = PasteboardService.capture(from: board)
        XCTAssertTrue(snapshot.containsFilePromises)
        XCTAssertFalse(snapshot.isRestorable)
        XCTAssertEqual(provider.requestCount, 0)
        XCTAssertEqual(snapshot.items.count, 2)
        withExtendedLifetime(provider) {}
    }

    @MainActor
    func testRealFilePromiseIsRejectedBeforeClearInsteadOfBecomingFileURL() throws {
        let board = makeBoard()
        defer { board.releaseGlobally() }
        let delegate = FilePromiseFixtureDelegate()
        let promise = NSFilePromiseProvider(fileType: UTType.plainText.identifier, delegate: delegate)
        XCTAssertTrue(board.writeObjects([promise]))
        let types = Set((board.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
        XCTAssertFalse(types.intersection(NSFilePromiseReceiver.readableDraggedTypes).isEmpty)
        let snapshot = PasteboardService.capture(from: board)
        XCTAssertTrue(snapshot.containsFilePromises)
        XCTAssertFalse(snapshot.isRestorable)
        let count = board.changeCount
        XCTAssertFalse(PasteboardService.restore(snapshot, to: board))
        XCTAssertEqual(board.changeCount, count)
        withExtendedLifetime(delegate) {}
    }
}
