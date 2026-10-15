import Foundation

/// Метаданные относятся к тому же сфокусированному элементу, что и снимок замены.
enum AutomaticTextContext: Equatable, Sendable {
    case prose
    case documentProse(document: String)
    case source(language: SourceLanguage, document: String, characterCount: Int?)
    case unverifiedSource(document: String)
    case unknown
}

enum SourceLanguage: Equatable, Sendable {
    case swift, javascript, python, cLike

    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "swift": self = .swift
        case "js", "mjs", "cjs", "ts": self = .javascript
        case "py", "pyw": self = .python
        case "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "java", "kt", "kts", "cs": self = .cLike
        default: return nil
        }
    }
}

/// Не заменяет парсер языка: неоднозначный участок запрещает автоматическую запись.
enum AutomaticTextPolicy {
    enum Region: Equatable {
        case prose, code, comment, string, unknown

        var allowsCorrection: Bool { self == .prose || self == .comment || self == .string }
    }

    static let maximumUTF16Count = 16_384

    static func region(text: String, wordRange: NSRange, context: AutomaticTextContext) -> Region {
        switch context {
        case .prose, .documentProse: return .prose
        case .unknown, .unverifiedSource: return .unknown
        case .source(let language, _, let characterCount):
            let units = Array(text.utf16.prefix(maximumUTF16Count + 1))
            guard units.count <= maximumUTF16Count, characterCount == units.count,
                  wordRange.location >= 0, wordRange.length > 0,
                  wordRange.location <= units.count,
                  wordRange.length <= units.count - wordRange.location,
                  isScalarBoundary(wordRange.location, in: units),
                  isScalarBoundary(NSMaxRange(wordRange), in: units),
                  Range(wordRange, in: text) != nil else { return .unknown }
            return SourceTextLexer(units: units, language: language).region(in: wordRange)
        }
    }

    private static func isScalarBoundary(_ position: Int, in units: [UInt16]) -> Bool {
        position == units.count || !(0xDC00...0xDFFF).contains(units[position])
    }
}

/// Метаданные проверяются без чтения файла и без анализа названия окна.
enum AutomaticDocumentPolicy {
    static func isDocumentEditor(_ bundleID: String) -> Bool {
        let identifiers: Set<String> = [
            "com.apple.TextEdit", "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
            "com.sublimetext.3", "com.sublimetext.4", "com.panic.Nova", "com.todesktop.230313mzl4w4u92",
            "ru.gigaide.ce", "ru.gigaide.ultimate"
        ]
        return identifiers.contains(bundleID) || bundleID.hasPrefix("com.jetbrains.")
    }

    static func isBrowser(_ bundleID: String) -> Bool {
        let identifiers: Set<String> = [
            "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
            "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "com.yandex.desktop.yandex-browser"
        ]
        return identifiers.contains(bundleID)
    }

    static func context(
        bundleID: String, role: String?, document: String?, characterCount: Int?,
        untitledDocumentIdentity: String? = nil
    ) -> AutomaticTextContext {
        guard role == "AXTextArea" || role == "AXTextField" else { return .unknown }
        if isBrowser(bundleID) { return .prose }
        let editorBody = isDocumentEditor(bundleID) && role == "AXTextArea"
        if bundleID == "com.apple.TextEdit", role == "AXTextArea", document == nil,
           let untitledDocumentIdentity {
            return .documentProse(document: untitledDocumentIdentity)
        }
        guard let document, let url = URL(string: document), url.isFileURL,
              url.path.hasPrefix("/") else { return editorBody ? .unknown : .prose }
        if let language = SourceLanguage(fileExtension: url.pathExtension) {
            return .source(language: language, document: url.absoluteString, characterCount: characterCount)
        }
        let proseExtensions: Set<String> = ["txt", "text", "md", "markdown", "rtf", "rtfd"]
        if proseExtensions.contains(url.pathExtension.lowercased()) {
            return .documentProse(document: url.absoluteString)
        }
        return .unknown
    }
}
