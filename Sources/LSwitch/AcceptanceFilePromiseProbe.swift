import AppKit
import Foundation
import LSwitchCore
import UniformTypeIdentifiers

private final class AcceptancePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    let contents = Data("Настоящий file promise LSwitch: файл создаётся по запросу получателя.\n".utf8)

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "LSwitch-promised.txt"
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try contents.write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}

private final class AcceptancePromiseReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Bool] = []
    private var errors: [String] = []

    func record(matches: Bool, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        results.append(matches)
        if let error { errors.append(error.localizedDescription) }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return results.count
    }

    var allMatch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !results.isEmpty && results.allSatisfy { $0 } && errors.isEmpty
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }
}

@MainActor
enum AcceptanceFilePromiseProbe {
    static func run() -> [String: Any] {
        let board = NSPasteboard(name: .init("ru.cramen.lswitch.probe.file-promise.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let delegate = AcceptancePromiseDelegate()
        let provider = NSFilePromiseProvider(fileType: UTType.plainText.identifier, delegate: delegate)
        defer { withExtendedLifetime(provider) {} }
        board.clearContents()
        guard board.writeObjects([provider]) else { return ["ok": false, "error": "file-promise-publish"] }
        let advertised = Set((board.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) })
        let recognized = !advertised.isDisjoint(with: NSFilePromiseReceiver.readableDraggedTypes)
        let snapshot = PasteboardService.capture(from: board)
        let before = board.changeCount
        let refused = !PasteboardService.restore(snapshot, to: board)
        let ownerPreserved = board.changeCount == before
        guard recognized, snapshot.containsFilePromises, refused, ownerPreserved else {
            return ["ok": false, "error": "file-promise-safety-gate", "types": advertised.sorted()]
        }
        // Вне dragging session AppKit может объявить promise с пустым окончательным именем.
        // Его receivePromisedFiles вызывает NSException, которую Swift do/catch не перехватывает.
        guard hasValidPromisedNames(board) else {
            return setupUnconfirmed("empty-or-invalid-promised-filename", types: advertised.sorted())
        }
        guard let receivers = board.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil)
            as? [NSFilePromiseReceiver], !receivers.isEmpty else {
            return setupUnconfirmed("receiver-unavailable-without-dragging-session", types: advertised.sorted())
        }
        return receive(receivers, delegate: delegate, types: advertised.sorted())
    }

    private static func hasValidPromisedNames(_ board: NSPasteboard) -> Bool {
        let nameType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-name")
        guard let items = board.pasteboardItems, !items.isEmpty else { return false }
        return items.allSatisfy { item in
            guard let name = item.string(forType: nameType), !name.isEmpty,
                  name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  !name.contains("\0"), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            return (name as NSString).lastPathComponent == name
        }
    }

    private static func setupUnconfirmed(_ reason: String, types: [String]) -> [String: Any] {
        ["ok": false, "status": "setup-unconfirmed", "error": reason,
         "genuineFilePromisePublished": true, "originalPromiseReceived": false,
         "restoreRefusedBeforeClear": true, "types": types, "fileURLSubstitution": false,
         "providerReceiverMatrixComplete": false]
    }

    private static func receive(
        _ receivers: [NSFilePromiseReceiver], delegate: AcceptancePromiseDelegate, types: [String]
    ) -> [String: Any] {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSwitchPromise-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            return ["ok": false, "error": "promise-destination: \(error.localizedDescription)"]
        }
        let receipt = AcceptancePromiseReceipt()
        let queue = OperationQueue()
        let expected = delegate.contents
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: destination, options: [:], operationQueue: queue
            ) { url, error in
                let owned = url.standardizedFileURL.deletingLastPathComponent() == destination.standardizedFileURL
                let matches = owned && error == nil && (try? Data(contentsOf: url)) == expected
                receipt.record(matches: matches, error: error)
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while receipt.count < receivers.count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        withExtendedLifetime(delegate) {}
        return ["ok": receipt.count == receivers.count && receipt.allMatch,
                "genuineFilePromise": true, "restoreRefusedBeforeClear": true,
                "receivers": receivers.count, "received": receipt.count, "dataMatches": receipt.allMatch,
                "errors": receipt.messages, "types": types, "destination": destination.path,
                "restoredPromiseSupported": false, "fileURLSubstitution": false,
                "providerReceiverMatrixComplete": false]
    }
}
