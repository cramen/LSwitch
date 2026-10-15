/// Совместимость клиентов clipboard после выделения общей границы отправки.
typealias ClipboardDispatchReply = ConversionDispatchReply
typealias ClipboardDispatchHooks = ConversionDispatchHooks

extension ClipboardCommand {
    var submissionKind: ConversionSafetySubmissionKind {
        switch self {
        case .selectCharacters, .selectWord: return .selection
        case .copy: return .copy
        case .paste: return .text
        case .collapseSelection: return .restoreSelection
        }
    }
}
