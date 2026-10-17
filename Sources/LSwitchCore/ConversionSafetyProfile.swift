import Foundation

/// Идентификатор принятого критерия наблюдения, а не системная capability или renderer ACK.
enum ConversionSafetyProfileIdentifier: String, Equatable, Sendable {
    case textEditAX119MacOS145

    var applicationVersion: String { "1.19" }
    var applicationBuild: String { "404" }
    var systemVersion: String { "14.5" }
    var systemBuild: String { "23F79" }
}

/// UUID обозначают удерживаемые provider-ом AX identity, не прочитанный текст или путь документа.
struct ConversionSafetyProfileBinding: Equatable, Sendable {
    let profile: ConversionSafetyProfileIdentifier
    let target: RecoveryProcessIdentity
    let documentIdentity: UUID
    let elementIdentity: UUID
    let windowIdentity: UUID
}

enum ConversionSafetyProfileStep: Equatable, Sendable {
    case selection, text, restoreSelection, finalState

    func matches(_ kind: ConversionSafetySubmissionKind) -> Bool {
        switch self {
        case .selection: return kind == .selection
        case .text: return kind == .text
        case .restoreSelection: return kind == .restoreSelection
        case .finalState: return false
        }
    }
}

enum ConversionSafetyProfileFault: Equatable, Sendable {
    case contextChanged, cancelled, writeRejected, snapshotUnavailable, snapshotMismatch, preparationFailed
    case unknownSubmission, outstandingKeyDebt, cleanupUnconfirmed, unconfirmedResult
}

/// Получается до чтения; одноразовый ticket не является свидетельством совпадения состояния.
struct ConversionSafetyProfileObservation: Equatable, Sendable {
    let operation: ConversionSafetyOperationToken
    let submission: ConversionSafetySubmissionToken?
    let step: ConversionSafetyProfileStep
    fileprivate let binding: ConversionSafetyProfileBinding
    fileprivate let revision: UInt64
}

/// Отдельная revision не позволяет новому cleanup-read случайно выдать старый profile result за свежий.
struct ConversionSafetyProfileState {
    let binding: ConversionSafetyProfileBinding
    private(set) var fault: ConversionSafetyProfileFault?
    private(set) var finalStateObserved = false
    private var revision: UInt64 = 0
    private var active: ConversionSafetyProfileObservation?

    init(binding: ConversionSafetyProfileBinding) { self.binding = binding }

    mutating func begin(
        operation: ConversionSafetyOperationToken, submission: ConversionSafetySubmissionToken?,
        step: ConversionSafetyProfileStep
    ) -> ConversionSafetyProfileObservation? {
        guard fault == nil, revision < UInt64.max else { return nil }
        invalidate()
        let observation = ConversionSafetyProfileObservation(
            operation: operation, submission: submission, step: step, binding: binding, revision: revision
        )
        active = observation
        return observation
    }

    mutating func accept(_ observation: ConversionSafetyProfileObservation) -> Bool {
        guard fault == nil, active == observation, observation.binding == binding else { return false }
        active = nil
        finalStateObserved = observation.step == .finalState
        return true
    }

    @discardableResult
    mutating func recordFault(_ reason: ConversionSafetyProfileFault) -> Bool {
        guard fault == nil else { return false }
        fault = reason
        invalidate()
        return true
    }

    mutating func invalidate() {
        if revision < UInt64.max { revision += 1 }
        active = nil
        finalStateObserved = false
    }
}
