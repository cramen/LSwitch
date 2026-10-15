import AppKit
import LSwitchCore

/// Изолированные варианты диагностической сборки. Остальные приложения используют штатный профиль.
@MainActor
enum AcceptanceOptions {
    private enum Engine: String { case accessibility = "ax", clipboard, keyboard }

    private static var selectedEngine: Engine? {
        #if DEBUG
        guard let bundle = argument("--test-app-bundle="),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle,
              let value = argument("--test-engine=") else { return nil }
        return Engine(rawValue: value)
        #else
        return nil
        #endif
    }

    static func prefersClipboard(defaultValue: Bool) -> Bool {
        switch selectedEngine {
        case .accessibility: return false
        case .clipboard, .keyboard: return true
        case nil: return defaultValue
        }
    }

    static func makeClipboardEngine() -> any ConversionEngine {
        #if DEBUG
        if selectedEngine == .accessibility { return UnavailableAcceptanceEngine() }
        if selectedEngine == .keyboard {
            var configuration = ClipboardConverter.Configuration()
            configuration.forceCopyForAcceptance = true
            return ClipboardConverter(acceptanceConfiguration: configuration, keyboardOnly: true)
        }
        #endif
        return ClipboardConversionEngine()
    }

    private static func argument(_ prefix: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}

#if DEBUG
@MainActor
private struct UnavailableAcceptanceEngine: ConversionEngine {
    func perform(_ request: ConversionRequest) async -> ConversionResult { .unavailable }
}
#endif
