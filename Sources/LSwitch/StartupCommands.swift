import AppKit
import LSwitchCore

/// Диагностические команды завершаются до создания штатного AppDelegate и запроса разрешений.
@MainActor
enum StartupCommands {
    static func runIfRequested(arguments: [String]) -> Int32? {
        if PasteboardCaptureHelper.runIfRequested(arguments: arguments) { return 0 }
        if let executable = Bundle.main.executableURL {
            ClipboardCaptureSupport.registerHelper(executableURL: executable)
        }
        if arguments.contains("--verify-resources") { return verifyResources() }
        if arguments.contains("--probe") { Probe.run() }
        if let status = RecoveryIsolationReceiver.runIfRequested(arguments: arguments) { return status }
        if let status = RecoveryIsolationProbe.runIfRequested(arguments: arguments) { return status }
        if let status = RecoveryWindowPreview.runIfRequested(arguments: arguments) { return status }
        if let status = RecoveryReceiverProbe.runIfRequested(arguments: arguments) { return status }
        return AcceptanceProbe.runIfRequested(arguments: arguments)
    }

    private static func verifyResources() -> Int32 {
        let dictionaries = DictionaryStore()
        let available = dictionaries.contains("привет", language: .russian)
            && dictionaries.contains("hello", language: .english)
        print("resources: \(DictionaryStore.resourceBundle.bundleURL.path)")
        print("dictionaries: \(available ? "ok" : "missing")")
        return available ? 0 : 1
    }
}
