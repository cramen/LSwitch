import Foundation

/// Host объявляет наличие ранней ветки PasteboardCaptureHelper в указанном executable.
/// Регистрация сама не запускает процесс и не обращается к clipboard.
@MainActor
public enum ClipboardCaptureSupport {
    static let capability = ClipboardHelperCapability()

    /// Первый локальный executable фиксируется на срок процесса. Повтор того же URL допустим.
    @discardableResult
    public static func registerHelper(executableURL: URL) -> Bool {
        capability.register(executableURL: executableURL)
    }
}

/// Отдельный реестр позволяет тестировать capability без изменения глобального host.
@MainActor
final class ClipboardHelperCapability {
    private(set) var executableURL: URL?
    private let isExecutable: (URL) -> Bool

    init(isExecutable: @escaping (URL) -> Bool = { url in
        var directory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: url.path)
    }) {
        self.isExecutable = isExecutable
    }

    @discardableResult
    func register(executableURL: URL) -> Bool {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/"),
              executableURL.query == nil, executableURL.fragment == nil,
              executableURL.host == nil || executableURL.host == "" || executableURL.host == "localhost" else {
            return false
        }
        let normalized = executableURL.standardizedFileURL
        if let registered = self.executableURL { return registered == normalized }
        guard isExecutable(normalized) else { return false }
        self.executableURL = normalized
        return true
    }
}
