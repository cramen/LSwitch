import ApplicationServices

struct AXWriteReply {
    let submission: ConversionSafetySubmissionToken
    let status: AXError
}

/// Подготовка владеет только значением; изменяющий RPC возможен лишь после beforeSend.
@MainActor
final class AXPreparedWrite {
    private let write: (ConversionSafetySubmissionToken?) -> AXError
    private var consumed = false

    init(write: @escaping (ConversionSafetySubmissionToken?) -> AXError) {
        self.write = write
    }

    func submit(beforeSend: () -> ConversionSafetySubmissionToken?) -> AXWriteReply? {
        guard !consumed else { return nil }
        consumed = true
        guard let submission = beforeSend() else { return nil }
        return AXWriteReply(submission: submission, status: write(submission))
    }

    /// Только прежний путь без ledger; подготовленное значение всё равно одноразовое.
    func submitUntracked() -> AXError? {
        guard !consumed else { return nil }
        consumed = true
        return write(nil)
    }
}
