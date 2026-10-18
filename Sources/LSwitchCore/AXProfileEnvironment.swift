import ApplicationServices
import Foundation

struct AXProfileContext {
    let process: RecoveryProcessIdentity
    let window: AXUIElement
    let document: String
    let bundleIdentifier: String
    let applicationVersion: String
    let applicationBuild: String
    let systemVersion: String
    let systemBuild: String
    let role: String

    var isSupported: Bool {
        let profile = ConversionSafetyProfileIdentifier.textEditAX119MacOS145
        return bundleIdentifier == "com.apple.TextEdit" && applicationVersion == profile.applicationVersion
            && applicationBuild == profile.applicationBuild && systemVersion == profile.systemVersion
            && systemBuild == profile.systemBuild && role == kAXTextAreaRole && !document.isEmpty
    }

    func matches(_ other: Self) -> Bool {
        process == other.process && CFEqual(window, other.window)
            && document.utf16.elementsEqual(other.document.utf16)
            && other.isSupported
    }
}

struct AXProfileSnapshot {
    static let maximumUTF16Units = 65_536
    let text: String
    let selection: NSRange
    let characterCount: Int

    var isComplete: Bool {
        let units = text.utf16
        let count = units.count
        guard count <= Self.maximumUTF16Units, characterCount == count,
              selection.location >= 0, selection.length >= 0,
              selection.location <= count, selection.length <= count - selection.location else { return false }
        return [selection.location, NSMaxRange(selection)].allSatisfy { position in
            let index = units.index(units.startIndex, offsetBy: position)
            return index == units.endIndex || !(0xDC00...0xDFFF).contains(units[index])
        } && Range(selection, in: text) != nil
    }
}

struct AXProfileExpectedState {
    let text: String
    let selections: [NSRange]

    init(_ text: String, _ selection: NSRange) {
        self.text = text
        selections = [selection]
    }

    init(text: String, selections: [NSRange]) {
        self.text = text
        self.selections = selections
    }
}

/// Метаданные читаются отдельно от payload; canRead проверяется перед каждым его системным чтением.
@MainActor
struct AXProfileEnvironment {
    let activeSource: () -> UnicodeInputSource?
    let focusedElement: () -> AXUIElement?
    let isProtected: (AXUIElement) -> Bool
    let context: (AXUIElement) -> AXProfileContext?
    let snapshot: (AXUIElement, () -> Bool) -> AXProfileSnapshot?
    /// Отсутствие этого provider запрещает combined boundary; старый request guard сохраняется отдельно.
    var foregroundProcessID: () -> Int32? = { nil }
}
