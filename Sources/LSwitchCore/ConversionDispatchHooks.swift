import ApplicationServices

/// Только метаданные фактической отправки; возврат AX/CG не является receiver ACK.
struct ConversionDispatchReply {
    enum Transport { case accessibility, menu, keyboard, unicode }
    let submission: ConversionSafetySubmissionToken
    let transport: Transport
    let status: AXError?

    var returnedSuccessfully: Bool { status == nil || status == .success }
}

@MainActor
struct ConversionDispatchHooks {
    var beforeSend: (ConversionSafetySubmissionKind) -> ConversionSafetySubmissionToken?
    var didReturn: (ConversionDispatchReply) -> Void
    var submissionCount: () -> Int = { 0 }
    var didLeaveDebt: (ConversionSafetySubmissionToken) -> Void = { _ in }
    var nativeBinding: NativeDispatchBinding?
}

/// Узкая команда выделения не предоставляет клиенту Copy/Paste.
enum NativeSelectionCommand: Equatable { case select(Int), collapse }
