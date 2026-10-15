import ApplicationServices

/// Только метаданные фактической отправки; возврат AX/CG не является receiver ACK.
struct ClipboardDispatchReply {
    enum Transport { case accessibility, menu, keyboard }
    let submission: ConversionSafetySubmissionToken
    let transport: Transport
    let status: AXError?

    var returnedSuccessfully: Bool { status == nil || status == .success }
}

@MainActor
struct ClipboardDispatchHooks {
    var beforeSend: (ConversionSafetySubmissionKind) -> ConversionSafetySubmissionToken?
    var didReturn: (ClipboardDispatchReply) -> Void
    var submissionCount: () -> Int = { 0 }
}

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
