import CoreGraphics

/// Recipient policy применяется только внутри endpoint уже выбранного per-PID tap.
/// Она не даёт права читать события глобального tap или обойти admission/квоты.
enum RecoveryCapturePolicy: Equatable, Sendable {
    case fixture(RecoveryFixtureCaptureFilter)
    case recipientInput

    func ownsHeader(type: CGEventType, sender: Int64, marker: Int64) -> Bool {
        switch self {
        case .fixture(let filter): return filter.ownsHeader(sender: sender, marker: marker)
        case .recipientInput: return InputEventBuffer.canHold(type)
        }
    }

    func matches(type: CGEventType, sender: Int64, marker: Int64) -> Bool {
        switch self {
        case .fixture(let filter):
            return marker != SyntheticEventMarker.magic && filter.matches(type: type, sender: sender, marker: marker)
        case .recipientInput: return InputEventBuffer.canHold(type)
        }
    }
}

/// Содержит только политику заголовков и реестр собственных marker, не очередь событий.
struct RecoveryCaptureTombstone: Sendable {
    let policy: RecoveryCapturePolicy
    let ownMarker: @Sendable (Int64, Int64) -> Bool

    func suppresses(type: CGEventType, event: CGEvent) -> Bool {
        let sender = event.getIntegerValueField(.eventSourceUnixProcessID)
        let marker = event.getIntegerValueField(.eventSourceUserData)
        return !ownMarker(sender, marker) && policy.ownsHeader(type: type, sender: sender, marker: marker)
    }
}
