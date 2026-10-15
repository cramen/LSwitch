import AppKit
import Darwin
import Foundation

/// Вызывается из ранней ветки main, до NSApp. stdout принадлежит только приватному pipe родителя.
public enum PasteboardCaptureHelper {
    static let argument = "--clipboard-capture-helper"

    @MainActor
    public static func runIfRequested(arguments: [String]) -> Bool {
        guard arguments.dropFirst().first == argument else { return false }
        let mainEntered = DispatchTime.now().uptimeNanoseconds
        var output = stat()
        guard arguments.count == 3, Thread.isMainThread,
              fstat(STDOUT_FILENO, &output) == 0, output.st_mode & S_IFMT == S_IFIFO else { return true }
        autoreleasepool {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(arguments[2]))
            let boardOpened = DispatchTime.now().uptimeNanoseconds
            let before = pasteboard.changeCount
            let snapshot = PasteboardService.capture(from: pasteboard)
            let after = pasteboard.changeCount
            let captureFinished = DispatchTime.now().uptimeNanoseconds
            let reply = PasteboardCaptureReply(
                snapshot: snapshot, changeCountBefore: before, changeCountAfter: after,
                timing: PasteboardHelperTiming(
                    mainEntered: mainEntered, boardOpened: boardOpened, captureFinished: captureFinished,
                    encodingStarted: DispatchTime.now().uptimeNanoseconds
                )
            )
            guard let data = try? JSONEncoder().encode(reply) else { return }
            try? FileHandle.standardOutput.write(contentsOf: data)
        }
        return true
    }
}
